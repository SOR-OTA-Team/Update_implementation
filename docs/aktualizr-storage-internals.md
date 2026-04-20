# aktualizr 스토리지 내부 동작

aktualizr가 구동되는 시점부터 바이너리 다운로드 완료까지 스토리지에 어떻게 접근하는지,
SQLite DB 구조, HSM 모드, 파일 atomicity, 락 메커니즘을 정리합니다.

---

## 1. 스토리지 종류

aktualizr는 세 가지 스토리지를 사용합니다.

| 스토리지 | 경로 | 용도 |
|---------|------|------|
| SQLite DB | `/var/sota/sql.db` | TUF 메타데이터, 키, ECU 정보, 설치 이력 |
| 이미지 파일시스템 | `/var/sota/images/<sha256>` | 다운로드된 바이너리 원본 |
| HSM (옵션) | PKCS#11 슬롯 | TLS/Uptane 키·인증서 (BUILD_P11 빌드 시) |

`StorageType::kFileSystem`(구 파일 기반 스토리지)은 최신 버전에서 제거되어 예외를 던집니다.
현재는 **SQLite만 지원**합니다.

---

## 2. SQLite DB 구조

### 스키마 파일 위치

```
config/sql/schema.sql              ← 현재 스키마 (버전 25)
config/sql/migration/migrate.00.sql
...
config/sql/migration/migrate.25.sql  ← 마이그레이션 이력
```

빌드 시 `src/libaktualizr/storage/embed_schemas.py`가 SQL 파일들을 C++ 문자열로 변환하여 바이너리에 내장합니다. aktualizr 실행 중 스키마 버전이 맞지 않으면 자동으로 마이그레이션합니다.

### 테이블 목록

| 테이블 | 저장 내용 |
|--------|---------|
| `version` | DB 스키마 버전 정수 |
| `device_info` | device_id, is_registered 플래그 (단일 행) |
| `ecus` | ECU serial, hardware_id, is_primary |
| `secondary_ecus` | Secondary ECU serial, 공개키, 캐시된 manifest |
| `misconfigured_ecus` | 불일치 ECU 상태 (kOld, kUnused) |
| `installed_versions` | 설치 이력: sha256, name, correlation_id, is_current, is_pending |
| `primary_keys` | Uptane 서명용 private/public 키 PEM (단일 행) |
| `tls_creds` | CA 인증서, 클라이언트 인증서, private key BLOB |
| `meta` | TUF 메타데이터 BLOB (repo × meta_type × version 유니크 인덱스) |
| `target_images` | targetname → 실제 파일명(sha256) 매핑 |
| `delegations` | TUF delegation 메타데이터 |
| `device_installation_result` | 설치 결과 (success, result_code, description) |
| `ecu_installation_results` | ECU별 설치 결과 |
| `need_reboot` | 재부팅 필요 여부 플래그 |
| `report_events` | 비동기 이벤트 로그 (JSON) |
| `ecu_report_counter` | ECU별 이벤트 보고 카운터 |
| `rollback_migrations` | 롤백 SQL 스크립트 저장 |

### `meta` 테이블 구조 (TUF 메타데이터 핵심)

```sql
CREATE TABLE meta (
  meta      BLOB NOT NULL,
  repo      INTEGER NOT NULL,   -- 0=image repo, 1=director
  meta_type INTEGER NOT NULL,   -- 0=root, 1=snapshot, 2=targets, 3=timestamp
  version   INTEGER NOT NULL,
  UNIQUE (repo, meta_type, version)
);
```

aktualizr는 director와 image 두 repo의 root/snapshot/targets/timestamp를 모두 이 테이블에 저장합니다.
업데이트 확인 시마다 최신 버전을 DB에서 읽어 TUF 검증 체인을 수행합니다.

---

## 3. INvStorage 인터페이스

`src/libaktualizr/storage/invstorage.h`에 정의된 순수 가상 인터페이스입니다.
`SQLStorage`가 이를 구현합니다.

```
INvStorage (인터페이스)
│
├── Primary 키         storePrimaryKeys / loadPrimaryKeys / clearPrimaryKeys
├── TLS 인증서         storeTlsCreds / loadTlsCreds / clearTlsCreds
│                      storeTlsCa / loadTlsCa
│                      storeTlsCert / loadTlsCert
│                      storeTlsPkey / loadTlsPkey
├── TUF 메타데이터     storeRoot / loadRoot
│                      storeNonRoot / loadNonRoot
│                      clearMetadata / clearNonRootMeta
├── Delegation         storeDelegation / loadDelegation / clearDelegations
├── 디바이스 등록       storeDeviceId / loadDeviceId
│                      storeEcuSerials / loadEcuSerials
│                      storeEcuRegistered / loadEcuRegistered
├── 설치 관리          saveInstalledVersion / loadInstalledVersions
│                      hasPendingInstall / getPendingEcus
│                      saveEcuInstallationResult
│                      storeDeviceInstallationResult
├── 이미지 파일 매핑   storeTargetFilename / getTargetFilename / deleteTargetInfo
└── 이벤트 보고        saveReportEvent / loadReportEvents / deleteReportEvents
```

팩토리 메서드:
```cpp
// invstorage.cc
std::shared_ptr<INvStorage> INvStorage::newStorage(const StorageConfig& config) {
  if (config.type == StorageType::kSqlite) {
    return std::make_shared<SQLStorage>(config);
  }
  throw std::runtime_error("unsupported storage type");  // kFileSystem 제거됨
}
```

---

## 4. 스토리지 접근 흐름

### 전체 흐름 (구동 → 다운로드 완료)

```
[aktualizr 시작]
       │
       ▼
Config 로드 (TOML 파싱)
       │
       ▼
INvStorage::newStorage()
  ├── SQLStorageBase 생성자
  │     ├── /var/sota/ 디렉토리 권한 확인 (S_IRWXU 전용)
  │     ├── storage.lock 파일락 획득  ← 프로세스 중복 실행 방지
  │     └── dbMigrate()               ← 스키마 버전 확인 / 자동 업그레이드
  │
  ▼
storage_->importData(config.import)
  ├── /var/sota/import/root.crt   존재하면 hash 비교 → tls_creds 테이블에 저장
  ├── /var/sota/import/client.pem  → tls_creds 테이블
  └── /var/sota/import/pkey.pem    → tls_creds 테이블
  (파일이 DB 내용과 동일하면 스킵)
       │
       ▼
Aktualizr::Initialize()
  ├── provisioner_.Prepare()
  │     └── loadTlsCreds() → tls_creds 테이블에서 인증서 로드
  ├── finalizeAfterReboot()
  │     └── loadInstalledVersions() → installed_versions 에서 pending 확인
  └── attemptProvision()
        ├── 미등록 시: PUT /director/ecus (ECU 등록)
        │              storeEcuSerials() → ecus 테이블 저장
        │              storeEcuRegistered() → device_info 업데이트
        └── 등록 완료 시: 스킵
       │
       ▼
[폴링 루프 시작 - polling_sec 간격]
       │
       ▼
SotaUptaneClient::updateDirectorMeta()
  ├── storage_->loadRoot(DIRECTOR, ver)   → meta 테이블 조회
  ├── fetcher_->fetchRole(DIRECTOR/root)  → 서버에서 최신 root.json 가져오기
  ├── storage_->storeRoot(...)            → meta 테이블 저장
  ├── 동일하게 snapshot, targets, timestamp 처리
  └── updateImagesMeta() (같은 패턴, image repo)
       │
       ▼
checkUpdates()
  └── storage_->loadNonRoot(DIRECTOR/targets) → 서버 타겟 목록 로드
      ↓ 신규 타겟 발견 시
       │
       ▼
downloadImages()
  ├── createTargetFile(target)
  │     ├── 파일명 = sha256 hex string
  │     ├── 경로   = config.pacman.images_path / sha256
  │     │           기본: /var/sota/images/<sha256hex>
  │     └── storage_->storeTargetFilename(targetname, sha256)
  │           → target_images 테이블 저장
  ├── HTTP GET /repo/targets/<파일>
  │     → std::ofstream으로 /var/sota/images/<sha256> 에 스트리밍 저장
  └── 해시 검증 (다운로드 완료 후 sha256 재계산하여 targets.json 값과 비교)
       │
       ▼
install()
  ├── (pacman type=none 이면 설치 생략)
  ├── saveInstalledVersion() → installed_versions 테이블 업데이트
  └── storeDeviceInstallationResult() → device_installation_result 저장
       │
       ▼
sendManifest()
  ├── loadEcuInstallationResults() → DB에서 결과 로드
  └── PUT /director/manifest  → 결과 서버 전송
```

---

## 5. 락(Lock) 및 동시성 보호

### 프로세스 간 — 파일락

```cpp
// sqlstorage_base.cc
StorageLock::StorageLock(boost::filesystem::path path) {
  fl_ = lock_path.c_str();          // boost::interprocess::file_lock
  if (!fl_.try_lock()) {
    throw StorageLock::locked_exception();
  }
}
```

- 락 파일: `/var/sota/storage.lock`
- `boost::interprocess::file_lock`으로 OS 레벨 파일락
- 두 번째 aktualizr 프로세스가 뜨면 `locked_exception` 예외 발생
- **readonly 모드에서는 락을 시도하지 않음**

### 스레드 간 — std::mutex + RAII

```cpp
// sql_utils.h
explicit SQLite3Guard(const boost::filesystem::path& path,
                      std::shared_ptr<std::mutex> mutex = nullptr) {
  if (m_) { m_->lock(); }
  // SQLITE_OPEN_NOMUTEX: SQLite 자체 뮤텍스 비활성화 → 외부 mutex로 직렬화
  sqlite3_open_v2(path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nullptr);
  sqlite3_busy_timeout(h, 2000);  // SQLITE_BUSY 시 2초 재시도
}
~SQLite3Guard() { if (m_) { m_->unlock(); } }
```

- `SQLStorageBase`가 `shared_ptr<std::mutex>`를 보유
- DB 접근 시마다 `dbConnection()`을 통해 같은 mutex 전달 → 직렬화
- **WAL 모드 미사용** — 단일 연결 직렬화로 충분하기 때문

### 트랜잭션

복수 테이블을 함께 수정하는 경우 명시적 트랜잭션 사용:
```sql
BEGIN TRANSACTION;
-- INSERT/UPDATE 복수 쿼리
COMMIT TRANSACTION;
-- 실패 시 ROLLBACK TRANSACTION
```

### 동시성 보호 요약

| 레벨 | 메커니즘 | 비고 |
|------|---------|------|
| 프로세스 간 | `file_lock` (`storage.lock`) | 실패 시 예외 |
| 스레드 간 | `std::mutex` (RAII) | DB 접근 직렬화 |
| SQLite | `SQLITE_OPEN_NOMUTEX` + `busy_timeout(2000)` | 외부 mutex에 위임 |
| 트랜잭션 | `BEGIN/COMMIT/ROLLBACK` | 복수 쿼리 원자성 |

---

## 6. 파일 Atomicity

### `Utils::writeFile` (`src/libaktualizr/utilities/utils.cc`)

```cpp
void Utils::writeFile(const boost::filesystem::path& filename, ...) {
  boost::filesystem::path tmpFilename = filename;
  tmpFilename += ".new";              // 임시 파일 (filename.new)

  std::ofstream file(tmpFilename.c_str());
  file.write(content, size);
  file.close();

  boost::filesystem::rename(tmpFilename, filename);  // POSIX rename() → atomic
}
```

- 임시 파일(`filename.new`)에 먼저 쓰고 `rename(2)`으로 교체
- POSIX `rename(2)`은 같은 파일시스템 내에서 원자적
- **fsync 미사용**: 전원 차단 내성은 rename 원자성에만 의존
- SQLite 수준의 durability는 SQLite 자체 journal이 담당

### `TemporaryFile`

TLS 키/인증서를 HSM 없이 사용할 때, DB BLOB → `/tmp/aktualizr-XXXXXX` 임시 파일로 추출하여 curl에 경로 전달. 소멸자에서 자동 삭제.

---

## 7. HSM 모드 (PKCS#11)

### 빌드 플래그

```cmake
# CMakeLists.txt
option(BUILD_P11 "Support for key storage in a HSM via PKCS#11" OFF)

if(BUILD_P11)
    find_package(LibP11 REQUIRED)
    add_definitions(-DBUILD_P11)
endif()
```

기본값 OFF. HSM을 사용하려면 `-DBUILD_P11=ON`으로 빌드해야 합니다.

### 파일 vs HSM 분기 (`keymanager.cc`)

```cpp
#ifdef BUILD_P11
static constexpr bool built_with_p11 = true;
#else
static constexpr bool built_with_p11 = false;
#endif

// TLS 키/인증서 로드
if (config_.tls.pkey_source == CryptoSource::kPkcs11) {
  // pkcs11:serial=...;pin-value=...;id=%NN URI를 curl에 직접 전달
  curl_easy_setopt(curl, CURLOPT_SSLKEY, p11_uri.c_str());
} else {
  // DB에서 BLOB 로드 → TemporaryFile로 추출 → 파일 경로 전달
  storage_->loadTlsPkey(&pkey_pem);
  tmp_pkey.PutContents(pkey_pem);
  curl_easy_setopt(curl, CURLOPT_SSLKEY, tmp_pkey.Path().c_str());
}
```

### HSM 키 조회 흐름

```
P11Engine::readUptanePublicKey(key_id)
  └── PKCS11_enumerate_public_keys()
        → hex id로 매칭
        → PEM 추출 반환

P11Engine::readTlsCert(id)
  └── PKCS11_enumerate_certs()
        → PEM 추출 반환

P11Engine::generateUptaneKeyPair()
  └── RSA2048 소프트웨어 생성
      → PKCS11_store_private_key()  ← HSM에 저장
      → PKCS11_store_public_key()
```

### HSM 설정 예시 (`aktualizr.toml`)

```toml
[tls]
server = "https://ota.ce:30443"
cert_source = "pkcs11"
pkey_source = "pkcs11"

[p11]
module = "/usr/lib/softhsm/libsofthsm2.so"
pass = "1234"
tls_clientcert_id = "01"
tls_pkey_id = "02"
uptane_key_id = "03"

[uptane]
key_source = "pkcs11"
```

---

## 8. TOML 설정 파일 전체 필드 정리

기본 탐색 경로 (알파벳 순으로 머지):
- `/usr/lib/sota/conf.d/*.toml`
- `/etc/sota/conf.d/*.toml`
- `--config` 플래그로 명시한 파일

### `[logger]`

| 필드 | 기본값 | 설명 |
|------|--------|------|
| `loglevel` | 2 | 0=trace, 1=debug, 2=info, 3=warning, 4=error, 5=fatal |

### `[tls]`

| 필드 | 기본값 | 설명 |
|------|--------|------|
| `server` | `""` | Device gateway URL (`https://ota.ce:30443`) |
| `server_url_path` | `""` | gateway URL을 파일에서 읽을 경우 경로 |
| `ca_source` | `"file"` | `"file"` 또는 `"pkcs11"` |
| `pkey_source` | `"file"` | `"file"` 또는 `"pkcs11"` |
| `cert_source` | `"file"` | `"file"` 또는 `"pkcs11"` |

### `[p11]` (HSM 전용)

| 필드 | 설명 |
|------|------|
| `module` | PKCS#11 라이브러리 경로 |
| `pass` | HSM PIN |
| `uptane_key_id` | Uptane 서명 키 hex ID |
| `tls_cacert_id` | TLS CA 인증서 hex ID |
| `tls_pkey_id` | TLS 클라이언트 private key hex ID |
| `tls_clientcert_id` | TLS 클라이언트 인증서 hex ID |

### `[provision]`

| 필드 | 기본값 | 설명 |
|------|--------|------|
| `mode` | `"Default"` | `"SharedCred"`, `"DeviceCred"`, `"SharedCredReuse"` |
| `provision_path` | `""` | SharedCred: credentials.zip 경로 |
| `device_id` | `""` | 수동 지정 device UUID |
| `primary_ecu_hardware_id` | `""` | Primary ECU 하드웨어 ID (예: `jetson-nano`) |
| `primary_ecu_serial` | `""` | 수동 지정 ECU serial (미설정 시 자동 생성) |
| `ecu_registration_endpoint` | `""` | 미설정 시 `tls.server + "/director/ecus"` |
| `p12_password` | `""` | SharedCred p12 파일 암호 |
| `expiry_days` | `"36000"` | 인증서 유효 기간 (일) |

### `[uptane]`

| 필드 | 기본값 | 설명 |
|------|--------|------|
| `polling_sec` | 10 | 업데이트 확인 폴링 간격 (초) |
| `director_server` | `""` | 미설정 시 `tls.server + "/director"` |
| `repo_server` | `""` | 미설정 시 `tls.server + "/repo"` |
| `key_source` | `"file"` | `"file"` 또는 `"pkcs11"` |
| `key_type` | `"RSA2048"` | `"RSA2048"`, `"RSA3072"`, `"RSA4096"`, `"ED25519"` |
| `force_install_completion` | false | 설치 완료 처리 강제 실행 |
| `secondary_config_file` | `""` | Secondary ECU 설정 파일 경로 |

### `[storage]`

| 필드 | 기본값 | 설명 |
|------|--------|------|
| `type` | `"sqlite"` | 현재 `"sqlite"` 만 지원 |
| `path` | `/var/sota` | 스토리지 기준 디렉토리 |
| `sqldb_path` | `sql.db` | SQLite DB 파일 (`path` 기준 상대경로 가능) |

### `[import]`

| 필드 | 기본값 | 설명 |
|------|--------|------|
| `base_path` | `/var/sota/import` | 임포트 기준 디렉토리 |
| `tls_cacert_path` | `""` | 임포트할 CA 인증서 파일 (상대경로: base_path 기준) |
| `tls_pkey_path` | `""` | 임포트할 TLS private key |
| `tls_clientcert_path` | `""` | 임포트할 TLS 클라이언트 인증서 |
| `uptane_private_key_path` | `""` | 임포트할 Uptane private key |
| `uptane_public_key_path` | `""` | 임포트할 Uptane public key |

`importData()`는 **Aktualizr 생성자에서 1회 호출**됩니다. 파일이 존재하면 현재 DB 내용과 hash 비교 후 변경된 경우에만 DB에 덮어씁니다.

### `[pacman]`

| 필드 | 기본값 | 설명 |
|------|--------|------|
| `type` | `"ostree"` | `"none"` (바이너리 저장만), `"ostree"` (OSTree 업데이트) |
| `images_path` | `/var/sota/images` | 다운로드 바이너리 저장 경로 |
| `os` | `""` | OSTree OS name |
| `sysroot` | `""` | OSTree sysroot 경로 |
| `ostree_server` | `""` | 미설정 시 `tls.server + "/treehub"` |
| `packages_file` | `/usr/package.manifest` | 패키지 목록 파일 |
| `fake_need_reboot` | false | 테스트용 재부팅 시뮬레이션 |

### `[bootloader]`

| 필드 | 기본값 | 설명 |
|------|--------|------|
| `rollback_mode` | `"none"` | `"none"`, `"uboot_generic"`, `"uboot_masked"` |
| `reboot_sentinel_dir` | `/var/run/aktualizr-session` | 재부팅 센티널 파일 디렉토리 |
| `reboot_sentinel_name` | `need_reboot` | 센티널 파일 이름 |
| `reboot_command` | `/sbin/reboot` | 재부팅 명령 |

---

## 9. 핵심 소스 파일 위치

| 목적 | 파일 |
|------|------|
| SQLite 스키마 | `config/sql/schema.sql` |
| 마이그레이션 | `config/sql/migration/migrate.NN.sql` (00~25) |
| 스토리지 인터페이스 | `src/libaktualizr/storage/invstorage.h` |
| SQLite 구현체 | `src/libaktualizr/storage/sqlstorage.cc` |
| 락·마이그레이션 기반 | `src/libaktualizr/storage/sqlstorage_base.cc` |
| SQLite Guard (RAII) | `src/libaktualizr/storage/sql_utils.h` |
| HSM 엔진 | `src/libaktualizr/crypto/p11engine.cc` |
| 키 관리 (파일/HSM 분기) | `src/libaktualizr/crypto/keymanager.cc` |
| 파일 atomic write | `src/libaktualizr/utilities/utils.cc` |
| 설정 파싱 | `src/libaktualizr/config/config.cc` |
| Aktualizr 초기화 | `src/libaktualizr/primary/aktualizr.cc` |
| TUF 메타 fetch/store | `src/libaktualizr/uptane/directorrepository.cc` |
| 다운로드·이미지 저장 | `src/libaktualizr/package_manager/packagemanagerinterface.cc` |
| 진입점 | `src/aktualizr_primary/main.cc` |
