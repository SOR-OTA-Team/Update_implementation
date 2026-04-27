# OTA 업데이트 테스트 아티팩트

실제 구현 테스트에서 생성·수집된 파일들입니다.  
Mac(OTA-CE 서버)과 Jetson Nano(aktualizr 클라이언트) 양쪽에서 추출했습니다.

> **주의**: 이 디렉토리의 키·인증서 파일은 로컬 테스트용입니다. 실제 환경에서 재사용하지 마세요.

---

## ⚠️ 이 테스트의 한계 — 정식 캠페인이 아님

이번 테스트에서 바이너리 전송은 **정식 캠페인 API를 통하지 않았습니다.**

### 정상적인 캠페인 흐름 (설계 의도)

```
campaigner API 호출
  → campaigner DB에 캠페인 레코드 생성
  → Kafka 메시지 → DaemonBoot의 CampaignScheduler 실행
  → director.setMultiUpdateTarget() 호출
  → director_v2.assignments 테이블 자동 생성
  → generated_metadata_outdated=1 자동 설정
  → aktualizr가 폴링하여 수신
```

### 실제 구현 방식 (DB 직접 조작)

```
push-update.sh 실행
  → reposerver에 바이너리 직접 업로드 (curl PUT)
  → director_v2.assignments 테이블에 SQL 직접 삽입
  → devices.generated_metadata_outdated=1 직접 SET
  → aktualizr가 폴링하여 수신
```

**우회한 이유**: OTA-CE에서 campaigner → director 내부 연결이 Kafka 메시지 버스를 통해 이루어지는데, 이 연결이 제대로 동작하지 않아 DB를 직접 조작하는 방식으로 대체했습니다.

따라서 `director_targets.json`에 `correlationId`가 존재하지만, 이는 정식 캠페인이 아닌 수동으로 생성한 ID입니다.

---

## 디렉토리 구조

```
test-artifacts/
├── server/
│   ├── credentials/        ← get-credentials.sh 실행 결과 (credentials.zip 내용)
│   └── tuf-metadata/       ← reposerver의 Image Repository TUF 메타데이터
└── jetson/
    ├── tuf-metadata/       ← aktualizr sql.db에서 추출한 TUF 메타데이터
    ├── import/             ← /var/sota/import/ 원본 인증서
    └── downloaded/         ← /var/sota/images/ 다운로드된 바이너리
```

---

## 파일 사이즈 요약

### server/credentials/ (credentials.zip 내용물)

| 파일 | 크기 | 역할 |
|------|------|------|
| `root.json` | 1,447B | TUF root 메타데이터 (4개 키 정의, ED25519 서명) |
| `targets.pub` | 127B | targets 서명 공개키 |
| `targets.sec` | 192B | targets 서명 개인키 |
| `server_ca.pem` | 591B | 서버 CA 인증서 |
| `device.crt` | 875B | 디바이스 클라이언트 인증서 |
| `autoprov.url` | 20B | gateway 주소 (`http://ota.ce:30443`) |
| `tufrepo.url` | 25B | reposerver 주소 |
| `treehub.json` | 97B | OSTree 서버 설정 |
| `device_uuid.txt` | 37B | 디바이스 UUID |
| **credentials.zip 합계** | **5.0KB** | aktualizr에 전달하는 패키지 |

### server/tuf-metadata/ (Image Repository)

| 파일 | 크기 | 내용 |
|------|------|------|
| `image_root.json` | 1,447B | root 메타데이터, version 1 |
| `image_snapshot.json` | 549B | snapshot 메타데이터 |
| `image_targets.json` | 599B | targets (test-binary.bin 포함), version 2 |
| `image_timestamp.json` | 424B | timestamp 메타데이터 |

### jetson/tuf-metadata/ (sql.db에서 추출)

| 파일 | 크기 | 내용 |
|------|------|------|
| `director_root.json` | 1,447B | Director root 메타데이터 |
| `director_targets.json` | 639B | Director targets (ECU ID 포함), version 2 |
| `image_targets.json` | 599B | Image targets (sql.db 저장본) |

> **참고**: director의 snapshot·timestamp는 sql.db에 저장되나 이번 추출에서 제외했습니다.  
> meta 테이블에서 `version=-1`로 저장된 항목이 aktualizr의 "최신 버전" 레코드입니다.

### jetson/import/ (/var/sota/import/)

| 파일 | 크기 | 역할 |
|------|------|------|
| `client.pem` | 875B | 디바이스 클라이언트 인증서 (mTLS) |
| `pkey.pem` | 1,704B | 디바이스 private key |
| `root.crt` | 591B | 서버 CA 인증서 |

> `/var/sota/import/`의 파일들은 aktualizr 최초 실행 시 hash 비교 후 sql.db의 `tls_creds` 테이블로 복사됩니다.  
> 이후 aktualizr는 이 디렉토리를 직접 참조하지 않고 DB만 사용합니다.

### jetson/downloaded/ (/var/sota/images/)

| 파일 | 크기 | 내용 |
|------|------|------|
| `test-binary.bin` | 19B | `hello OTA world v1` |

> 실제 저장 경로: `/var/sota/images/E96547C924DEE500A95EDD5C44E40606BEF4C72431AA3CFCF655645A6B747C8F`  
> 파일명은 sha256 해시값 그대로 사용됩니다.

---

## 메타데이터 생성 과정

### 단계별 생성 시점

| 단계 | 실행 | 생성된 메타데이터 | 저장 위치 |
|------|------|----------------|---------|
| Step 1-1 | `gen-server-certs.sh` | 서버 CA, device CA, TUF root 키쌍 | `ota-ce-gen/` 파일 |
| Step 1-5 | `get-credentials.sh` | `root.json` 서명, `targets.pub/sec` | `ota-ce-gen/` + keyserver DB |
| Step 2 | `gen-device-cert.sh` | `device.crt` (mTLS 인증서, TUF 메타 아님) | `ota-ce-gen/` 파일 |
| Step 5 | aktualizr 최초 실행 | Uptane 서명 키쌍, ECU serial 생성 | `sql.db` primary_keys, ecus |
| Step 5 | aktualizr 서버 연결 | TUF root/snapshot/targets/timestamp 수신 | `sql.db` meta 테이블 |
| Step 6 | `push-update.sh` | image targets.json 갱신, director targets.json 재서명 | reposerver DB, director DB |

---

## sql.db meta 테이블 구조

```
repo=0 → Image Repository
repo=1 → Director Repository

meta_type=0 → root
meta_type=1 → snapshot
meta_type=2 → targets
meta_type=3 → timestamp

version=-1  → aktualizr 내부 규칙: "최신 버전" 레코드
version=N   → 명시적으로 버전이 필요한 root만 양수 버전 저장
```

실제 저장 상태:

| repo | meta_type | version | 크기 | 설명 |
|------|-----------|---------|------|------|
| 0 (image) | 0 (root) | 1 | 1,447B | image root, 버전 명시 |
| 0 (image) | 1 (snapshot) | -1 | 549B | image snapshot 최신 |
| 0 (image) | 2 (targets) | -1 | 599B | image targets 최신 |
| 0 (image) | 3 (timestamp) | -1 | 424B | image timestamp 최신 |
| 1 (director) | 0 (root) | 1 | 1,447B | director root, 버전 명시 |
| 1 (director) | 2 (targets) | -1 | 639B | director targets 최신 |

---

## image_targets vs director_targets 비교

| 항목 | image_targets | director_targets |
|------|--------------|-----------------|
| 대상 | 전체 공개 | 특정 디바이스 전용 |
| 식별자 | `hardwareIds: ["jetson-nano"]` | `ecuIdentifiers: { "f50cef40...": {...} }` |
| correlationId | 없음 | `urn:here-ota:campaign:<uuid>` (수동 생성) |
| 서명 키 | reposerver targets 키 | director 전용 키 |
| Uptane 검증 역할 | sha256 기준값 제공 | sha256 일치 확인 |

두 파일의 **sha256이 일치해야** aktualizr가 다운로드를 진행합니다 (Uptane 이중 검증).

---

## director targets v1 vs v2 비교

**v1 — 디바이스 등록 직후 (빈 상태)**
```json
{
  "signed": {
    "targets": {},
    "version": 1,
    "_type": "Targets"
  }
}
```

**v2 — push-update.sh 실행 후 (바이너리 할당)**
```json
{
  "signed": {
    "targets": {
      "test-binary.bin": {
        "hashes": { "sha256": "e96547c..." },
        "length": 19,
        "custom": {
          "ecuIdentifiers": {
            "f50cef40...": { "hardwareId": "jetson-nano" }
          }
        }
      }
    },
    "version": 2,
    "custom": { "correlationId": "urn:here-ota:campaign:cf97cbe7-..." },
    "_type": "Targets"
  }
}
```

---

## File Atomicity 관점

### 바이너리 다운로드 — rename 패턴 미사용

바이너리 파일(`/var/sota/images/<sha256>`)은 **스트리밍 직접 쓰기**로 저장됩니다.

```
rename 패턴 (TUF 메타데이터 파일용):
  tmpfile.new 생성 → 전부 쓰기 → rename() → 원자적 교체

바이너리 이미지 (직접 스트리밍):
  파일 열기 → HTTP 수신하며 청크 단위로 직접 쓰기
  → 다운로드 중 전원 차단 시 절반만 쓰인 파일 남을 수 있음
```

대신 **sha256 해시 검증**으로 무결성을 보완합니다:
- 다운로드 완료 후 sha256 재계산
- director_targets와 image_targets의 해시값과 비교
- 불일치 시 파일 삭제 후 재다운로드

→ 파일의 atomic write는 보장하지 않지만, **최종 저장된 파일의 무결성은 해시로 보장**합니다.

### TUF 메타데이터 — SQLite 트랜잭션으로 보장

sql.db에 저장되는 TUF 메타데이터는 SQLite 트랜잭션으로 원자성이 보장됩니다.

```sql
BEGIN TRANSACTION;
  INSERT INTO meta (meta, repo, meta_type, version) VALUES (...);
COMMIT;
-- 중간 실패 시 ROLLBACK → 이전 상태 유지
```

### import 파일 → DB 복사 — hash 비교 후 덮어쓰기

`/var/sota/import/` 파일들을 DB로 복사할 때는 hash 비교 후 변경 시에만 쓰기를 수행합니다.
파일 자체에 rename 패턴을 쓰지 않으나, DB 쓰기는 트랜잭션으로 보호됩니다.

### 정리

| 대상 | atomicity 방식 | 보장 수준 |
|------|--------------|---------|
| TUF 메타데이터 (sql.db) | SQLite 트랜잭션 | 완전 보장 |
| 바이너리 이미지 | 직접 스트리밍 + sha256 검증 | 무결성 보장, atomic write 아님 |
| import → DB 복사 | hash 비교 + SQLite 트랜잭션 | 완전 보장 |
| 설정 파일 쓰기 | rename 패턴 (tmpfile + rename) | 완전 보장 |

---

## aktualizr sql.db 스토리지 요약

- **경로**: `/var/lib/aktualizr/sql.db`
- **크기**: 148KB
- **스키마 버전**: 25

| 테이블 | 저장 내용 |
|--------|---------|
| `device_info` | device_id: `af3da729-...`, is_registered: 1 |
| `ecus` | serial: `f50cef40-...`, hardware_id: `jetson-nano`, is_primary: 1 |
| `tls_creds` | ca_cert(591B) / client_cert(875B) / client_pkey(1,704B) |
| `primary_keys` | Uptane 서명 키 private(1,675B) / public(451B) |
| `meta` | TUF 메타데이터 6개 레코드 (image 4개 + director 2개) |
| `target_images` | `test-binary.bin` → `E96547C...` 매핑 |
| `installed_versions` | sha256, name, is_current=1, is_pending=0 |
| `device_installation_result` | **비어있음** |

> **`device_installation_result`가 비어있는 이유**:  
> aktualizr.toml에서 `[pacman] type = "none"` 으로 설정했기 때문입니다.  
> `type=none`은 파일을 `/var/sota/images/`에 저장만 하고 실제 설치를 수행하지 않습니다.  
> 설치 결과가 없으므로 `device_installation_result`에 레코드가 생성되지 않습니다.  
> `installed_versions`의 `is_current=1`은 다운로드 완료 상태를 나타내며, 설치 완료와는 다릅니다.

---

## 테스트 환경 정보

| 항목 | 값 |
|------|----|
| Mac IP | 192.168.0.147 |
| Jetson IP | 192.168.0.154 |
| Device UUID | `af3da729-5b0f-4c30-a2b5-aafaa44114ae` |
| ECU Serial | `f50cef40cdf439cb7c1843f0b8c3b7c20277e0b1f23cd6052c54ebb40c6d5b34` |
| 테스트 파일 | `test-binary.bin` (19B, `hello OTA world v1`) |
| 파일 sha256 | `e96547c924dee500a95edd5c44e40606bef4c72431aa3cfcf655645a6b747c8f` |
| 저장 경로 | `/var/sota/images/E96547C924DEE500A95EDD5C44E40606BEF4C72431AA3CFCF655645A6B747C8F` |
