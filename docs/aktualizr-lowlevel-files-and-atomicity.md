# aktualizr 저수준 파일 구조 및 Atomicity

---

## 1. 관련 파일 전체 목록 및 역할

### Jetson 파일시스템 기준

```
/etc/aktualizr/
└── aktualizr.toml          ← 실행 설정 (직접 작성)

/var/sota/
├── sql.db                  ← SQLite DB (TUF 메타, 키, 인증서, 설치 이력)
├── storage.lock            ← 프로세스 중복 실행 방지용 잠금 파일
└── images/
    └── <sha256hex>         ← 다운로드된 바이너리 파일

/var/sota/import/           ← 최초 실행 시 DB로 복사될 원본 파일
├── root.crt                ← 서버 CA 인증서
├── client.pem              ← 디바이스 클라이언트 인증서
└── pkey.pem                ← 디바이스 private key

/var/lib/aktualizr/         ← 구버전 호환 경로 (현재는 /var/sota/sql.db 사용)
```

### TOML 파일이란

설정값을 사람이 읽기 쉽게 적어둔 텍스트 파일입니다.
aktualizr를 설치해도 TOML 파일은 자동으로 생성되지 않으므로 **직접 작성**해야 합니다.

```toml
# 섹션 이름
[tls]
server = "https://ota.ce:30443"   # 키 = 값

[uptane]
polling_sec = 10
```

기본 탐색 경로 (알파벳 순으로 머지):
```
/usr/lib/sota/conf.d/*.toml
/etc/sota/conf.d/*.toml
```
`--config` 플래그로 직접 지정하면 위 경로는 무시됩니다.

```bash
sudo aktualizr --config /etc/aktualizr/aktualizr.toml
```

---

## 2. 스토리지 접근 Flow (권한 및 Lock 포함)

### 전체 흐름

```
$ sudo aktualizr --config /etc/aktualizr/aktualizr.toml
        │
        ▼
[1] Config 로드 (main.cc)
    read_ini(aktualizr.toml)
    → C++ 구조체(Config)에 파싱 결과 저장
        │
        ▼
[2] Aktualizr 생성자 (aktualizr.cc)
        │
        ├─[2-1] INvStorage::newStorage(config.storage)
        │           │
        │           ▼
        │       SQLStorageBase 생성자
        │           │
        │           ├── /var/sota/ 디렉토리 권한 검사
        │           │   S_IRWXU(700) 아니면 예외 발생
        │           │
        │           ├── StorageLock("/var/sota/storage.lock")
        │           │   file_lock.try_lock()
        │           │   실패 → locked_exception (두 번째 프로세스 차단)
        │           │
        │           └── dbMigrate()
        │               schema 버전 확인 → 필요 시 자동 업그레이드
        │
        ├─[2-2] storage_->importData(config.import)
        │           │
        │           ├── /var/sota/import/root.crt   존재 확인
        │           │   현재 DB hash와 비교 → 다르면 tls_creds 테이블에 저장
        │           ├── /var/sota/import/client.pem → tls_creds 테이블
        │           └── /var/sota/import/pkey.pem   → tls_creds 테이블
        │           (이후로는 import/ 파일 직접 참조 안 함, DB만 사용)
        │
        └─[2-3] SotaUptaneClient 생성
                    └── storage_->loadTlsCreds() → tls_creds 테이블에서 로드
        │
        ▼
[3] Aktualizr::Initialize()
    ├── provisioner_.Prepare()
    │   DB에서 TLS 인증서 로드 → 서버에 mTLS 연결 시도
    │
    ├── finalizeAfterReboot()
    │   installed_versions 테이블에서 pending 항목 확인
    │
    └── attemptProvision()
        ├── 미등록: PUT /director/ecus
        │          storeEcuSerials() → ecus 테이블
        │          storeEcuRegistered() → device_info 테이블
        └── 등록됨: 스킵
        │
        ▼
[4] 폴링 루프 (polling_sec 간격)
    │
    ├── PUT /director/manifest (내 상태 전송)
    │
    ├── updateDirectorMeta()
    │   ├── storage_->loadRoot(DIRECTOR)    → meta 테이블 조회
    │   ├── HTTP GET director/root.json
    │   ├── storage_->storeRoot(...)        → meta 테이블 저장
    │   └── snapshot, targets, timestamp 동일 반복
    │
    ├── updateImagesMeta() (image repo 동일 패턴)
    │
    └── 신규 타겟 발견 시
            │
            ▼
[5] downloadImages()
    ├── createTargetFile(target)
    │   파일명 = sha256 hex string
    │   경로   = /var/sota/images/<sha256>
    │   storage_->storeTargetFilename() → target_images 테이블
    │
    ├── HTTP GET /repo/targets/<파일>
    │   → std::ofstream으로 /var/sota/images/<sha256> 에 스트리밍 저장
    │
    └── 해시 검증 (sha256 재계산 → targets.json 값과 비교)
            │
            ▼
[6] install() / 결과 저장
    ├── saveInstalledVersion() → installed_versions 테이블
    ├── storeDeviceInstallationResult() → device_installation_result 테이블
    └── PUT /director/manifest (결과 서버 전송)
            │
            ▼
[7] 프로세스 종료 시
    StorageLock 소멸자 호출
    → OS가 file_lock 자동 해제
    → storage.lock 잠금 풀림
```

### 접근 권한 구조

| 경로 | 권한 | 소유자 | 비고 |
|------|------|--------|------|
| `/var/sota/` | `700` (rwx------) | root | 다른 권한이면 aktualizr 실행 거부 |
| `/var/sota/sql.db` | `600` (rw-------) | root | root만 읽기/쓰기 가능 |
| `/var/sota/storage.lock` | `600` | root | file_lock 용도 |
| `/var/sota/images/` | `700` | root | 다운로드 파일 저장소 |
| `/var/sota/import/` | `600` | root | 초기 인증서 원본, 이후 참조 안 함 |

aktualizr는 `sudo`로 실행해야 하는 이유가 이 권한 구조 때문입니다.

---

## 3. File Atomicity

### 보장하는 단위

aktualizr에서 atomicity는 **두 가지 레벨**에서 각각 다른 방식으로 보장됩니다.

| 레벨 | 대상 | 방식 |
|------|------|------|
| 파일 레벨 | 설정/메타데이터 파일 쓰기 | rename 패턴 |
| DB 레벨 | SQLite 테이블 쓰기 | 트랜잭션 |
| 다운로드 파일 | 바이너리 이미지 | 해시 검증 (쓰기 자체는 atomic 아님) |

---

### 파일 레벨: rename 패턴

#### 동작 방식

```
직접 쓰기 (문제):
  파일 열기 → 쓰는 중... → [전원 차단] → 절반만 쓰인 파일 남음

rename 패턴 (해결):
  임시파일.new 생성
  → 임시파일.new에 전부 쓰기 완료
  → rename(임시파일.new, 목적파일)   ← 이 한 순간만 원자적
  → 완료 또는 실패, 중간 상태 없음
```

#### 실제 코드 (`src/libaktualizr/utilities/utils.cc`)

```cpp
void Utils::writeFile(const boost::filesystem::path& filename, ...) {

    // 1. 임시 파일 경로 생성 (filename + ".new")
    boost::filesystem::path tmpFilename = filename;
    tmpFilename += ".new";

    // 2. 임시 파일에 전부 쓰기
    std::ofstream file(tmpFilename.c_str());
    file.write(content, size);
    file.close();

    // 3. 원자적 교체
    boost::filesystem::rename(tmpFilename, filename);
    // 내부적으로 POSIX rename(2) 호출
    // 같은 파일시스템 내에서 원자적으로 보장
}
```

#### 언제 시작하고 끝나는가

```
시작: writeFile() 호출 시점
  └── tmpFilename + ".new" 파일 생성

진행: 데이터 전부 쓰기
  └── 이 구간에서 전원 차단되면 ".new" 파일만 남음 (원본은 안전)

끝: rename() 호출 시점
  └── 이 순간 원자적으로 교체 완료
  └── 성공 or 실패, 중간 상태 없음
```

전원 차단 시나리오별 결과:

```
쓰기 중 차단   → ".new" 파일만 남음, 원본 파일은 이전 내용 그대로 유지
rename 전 차단 → 동일 (원본 안전)
rename 후 차단 → 새 내용으로 교체 완료된 상태
```

#### fsync 미사용

rename은 원자적이지만 **내구성(durability)** 은 보장하지 않습니다.
OS 페이지 캐시에 머물다가 전원이 나가면 디스크에 안 쓰인 상태가 될 수 있습니다.
aktualizr는 `fsync()`를 명시적으로 호출하지 않으므로, SQLite DB가 제공하는 journal 기반 내구성에 의존합니다.

---

### DB 레벨: SQLite 트랜잭션

여러 테이블을 함께 수정할 때 트랜잭션으로 묶어 원자성을 보장합니다.

```cpp
// 예: ECU 등록 시
BEGIN TRANSACTION;
  INSERT INTO ecus (serial, hardware_id, is_primary) VALUES (...);
  UPDATE device_info SET is_registered = 1;
COMMIT TRANSACTION;
-- 중간에 실패하면 ROLLBACK → 두 쿼리 모두 취소
```

SQLite는 WAL(Write-Ahead Log) 또는 journal 파일을 통해 트랜잭션 내구성을 보장합니다.

---

### 다운로드 파일: 해시 검증

바이너리 이미지(`/var/sota/images/<sha256>`)는 rename 패턴을 쓰지 않고 스트리밍으로 직접 씁니다.
대신 다운로드 완료 후 **sha256을 재계산**하여 targets.json 값과 비교합니다.

```
다운로드 중 전원 차단
  → 파일이 절반만 쓰인 상태로 남음
  → 다음 실행 시 해시 불일치 → 파일 삭제 후 재다운로드
```

---

### Lock 구조 전체 정리

| 레벨 | 메커니즘 | 적용 시점 | 해제 시점 |
|------|---------|----------|----------|
| 프로세스 간 | `file_lock` (storage.lock) | SQLStorageBase 생성자 | 프로세스 종료 시 OS 자동 해제 |
| 스레드 간 | `std::mutex` (RAII) | DB 접근 시마다 | 접근 완료 즉시 |
| SQLite | `busy_timeout(2000ms)` | SQLITE_BUSY 발생 시 | 2초 내 재시도 |
| 트랜잭션 | `BEGIN/COMMIT/ROLLBACK` | 복수 쿼리 시작 시 | COMMIT 또는 ROLLBACK |

```
프로세스 A 실행
  │
  ├── storage.lock 획득      ← 프로세스 레벨 보호 시작
  │
  ├── 스레드 1: 폴링
  │     └── mutex 획득 → DB 읽기 → mutex 해제
  │
  ├── 스레드 2: 다운로드
  │     └── mutex 획득 → DB 쓰기 → mutex 해제
  │         (스레드 1과 동시 접근 불가)
  │
  └── 프로세스 종료
        └── storage.lock 자동 해제   ← 프로세스 레벨 보호 종료
```
