# OTA 업데이트 테스트 아티팩트

실제 구현 테스트에서 생성·수집된 파일들입니다.  
Mac(OTA-CE 서버)과 Jetson Nano(aktualizr 클라이언트) 양쪽에서 추출했습니다.

> **주의**: 이 디렉토리의 키·인증서 파일은 로컬 테스트용입니다. 실제 환경에서 재사용하지 마세요.

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

### jetson/import/ (/var/sota/import/)

| 파일 | 크기 | 역할 |
|------|------|------|
| `client.pem` | 875B | 디바이스 클라이언트 인증서 (mTLS) |
| `pkey.pem` | 1,704B | 디바이스 private key |
| `root.crt` | 591B | 서버 CA 인증서 |

### jetson/downloaded/ (/var/sota/images/)

| 파일 | 크기 | 내용 |
|------|------|------|
| `test-binary.bin` | 19B | `hello OTA world v1` |

---

## 메타데이터 생성 과정

### 단계별 생성 시점

| 단계 | 실행 | 생성된 메타데이터 |
|------|------|----------------|
| Step 1-1 | `gen-server-certs.sh` | 서버 CA, device CA, TUF root 키쌍 |
| Step 1-5 | `get-credentials.sh` | `root.json` 서명, `targets.pub/sec` 생성 |
| Step 2 | `gen-device-cert.sh` | `device.crt` (mTLS 인증서) |
| Step 5 | aktualizr 최초 실행 | Uptane 키쌍, ECU serial → `sql.db` 저장 |
| Step 5 | aktualizr 서버 연결 | TUF root/snapshot/targets/timestamp → `sql.db meta 테이블` |
| Step 6 | `push-update.sh` | image targets.json 갱신, director targets.json 재서명 |

---

## 캠페인 생성 vs 메타데이터 생성 비교

### director targets.json 버전 변화

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

### image_targets vs director_targets 차이점

| 항목 | image_targets | director_targets |
|------|--------------|-----------------|
| 대상 | 전체 공개 | 특정 디바이스 전용 |
| 식별자 | `hardwareIds: ["jetson-nano"]` | `ecuIdentifiers: { "f50cef40...": {...} }` |
| correlationId | 없음 | `urn:here-ota:campaign:<uuid>` |
| 서명 키 | reposerver targets 키 | director 전용 키 |
| Uptane 검증 | sha256 일치 여부 비교 대상 | sha256 일치 여부 비교 대상 |

두 파일의 **sha256이 일치해야** aktualizr가 다운로드를 진행합니다 (Uptane 이중 검증).

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
