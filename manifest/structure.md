# Manifest 구조 상세

소스코드를 직접 읽어 파악한 manifest JSON 필드 전체 정리입니다.

---

## 참고한 소스코드

### 클라이언트 (sor_aktualizr, C++)

| 파일 | 역할 |
|------|------|
| `src/libaktualizr/primary/sotauptaneclient.cc` | `AssembleManifest()` — manifest 조립 및 `putManifestSimple()` — PUT 전송 |
| `src/libaktualizr/uptane/manifest.cc` | `assembleManifest()` — ECU 개별 manifest 조립 |
| `include/libaktualizr/types.h` | `InstalledImageInfo { name, len, hash }` — 파일 정보 구조체 |

### 서버 (sor_ota_ce, Scala)

| 파일 | 역할 |
|------|------|
| `repos/director/.../data/DeviceRequest.scala` | `DeviceManifest`, `EcuManifest` case class — JSON 필드 정의 |
| `repos/director/.../manifest/DeviceManifestProcess.scala` | 버전 판별 로직 (`manifestVersion()`) |
| `repos/director/.../manifest/ManifestCompiler.scala` | 수신 후 처리 — sha256 비교, assignment 완료 처리 |
| `repos/director/src/test/resources/device_manifests/` | v1/v2/v3 실제 예시 JSON |

---

## 전체 필드 구조

```
manifest
├── signatures[]                     ← Primary ECU Uptane 키로 서명한 외부 서명
│   ├── keyid                           Primary 공개키 ID
│   ├── method                          "ed25519" 또는 "rsassa-pss"
│   └── sig                             Base64 서명값
│
└── signed
    ├── primary_ecu_serial           ← 디바이스 Primary ECU serial
    │
    ├── ecu_version_manifests        ← ECU별 현재 상태 (Map: serial → manifest)
    │   └── "<ECU serial>"
    │       ├── signatures[]            ECU 개별 서명
    │       └── signed
    │           ├── ecu_serial
    │           ├── installed_image
    │           │   ├── filepath            현재 파일 이름 ("test-binary.bin")
    │           │   └── fileinfo
    │           │       ├── hashes.sha256   현재 파일 sha256
    │           │       └── length          파일 크기 (bytes)
    │           ├── attacks_detected        이상 감지 여부 (보통 빈 문자열 "")
    │           ├── previous_timeserver_time
    │           └── timeserver_time
    │
    └── installation_report          ← 설치 완료 후에만 포함 (v3 전용)
        ├── content_type                "application/vnd.com.here.otac.installationReport.v1"
        └── report
            ├── correlation_id          캠페인 ID ("urn:here-ota:campaign:<uuid>")
            ├── result
            │   ├── success             true / false
            │   ├── code                "OK" 또는 에러코드
            │   └── description
            ├── items[]                 ECU별 개별 결과
            │   ├── ecu                 ECU serial
            │   └── result.success
            └── raw_report              설치 로그 원문 (optional)
```

---

## 필드별 소스코드 근거

### `installed_image` 필드 — `manifest.cc`

```cpp
// src/libaktualizr/uptane/manifest.cc
Manifest ManifestIssuer::assembleManifest(const InstalledImageInfo &installed_image_info) {
  installed_image["filepath"] = installed_image_info.name;           // 파일 이름
  installed_image["fileinfo"]["length"] = installed_image_info.len;  // 파일 크기
  installed_image["fileinfo"]["hashes"]["sha256"] = installed_image_info.hash; // sha256

  unsigned_ecu_version["attacks_detected"] = "";
  unsigned_ecu_version["installed_image"] = installed_image;
  unsigned_ecu_version["ecu_serial"] = ecu_serial.ToString();
  unsigned_ecu_version["previous_timeserver_time"] = "1970-01-01T00:00:00Z";
  unsigned_ecu_version["timeserver_time"] = "1970-01-01T00:00:00Z";
}
```

### `installation_report` 필드 — `sotauptaneclient.cc`

```cpp
// src/libaktualizr/primary/sotauptaneclient.cc
bool has_results = storage->loadDeviceInstallationResult(&dev_result, &raw_report, &correlation_id);
if (has_results) {
    installation_report["result"]         = dev_result.toJson();   // success, code
    installation_report["raw_report"]     = raw_report;
    installation_report["correlation_id"] = correlation_id;        // 캠페인 ID
    installation_report["items"]          = ...;                   // ECU별 결과

    manifest["installation_report"]["content_type"] = "application/vnd.com.here.otac.installationReport.v1";
    manifest["installation_report"]["report"] = installation_report;
} else {
    LOG_DEBUG << "No installation result to report in manifest";   // 결과 없으면 필드 없음
}
```

### 데이터 타입 정의 — `DeviceRequest.scala`

```scala
// Scala case class 필드명 = JSON 키 이름
case class DeviceManifest(
  primary_ecu_serial:      EcuIdentifier,
  ecu_version_manifests:   Map[EcuIdentifier, SignedPayload[EcuManifest]],
  installation_report:     Option[InstallationReportEntity]  // Option = 없을 수 있음
)

case class EcuManifest(
  installed_image:  Image,
  ecu_serial:       EcuIdentifier,
  attacks_detected: String,
  custom:           Option[Json]   // operation_result (v2 레거시)
)
```

---

## 버전별 차이

버전 판별은 서버가 특정 필드의 존재 여부로 합니다 (`DeviceManifestProcess.scala`):

```scala
def manifestVersion(manifest: Json): Int = {
  if (manifest.hcursor.downField("installation_report").succeeded) 3   // v3
  else if (manifest.hcursor.downField("ecu_version_manifest").succeeded) 1  // v1
  else if (manifest.findAllByKey("operation_result").nonEmpty) 2        // v2
  else latestVersion  // 기본값 = 3
}
```

| 버전 | `ecu_version_manifests` 형태 | 설치 결과 필드 |
|------|------------------------------|----------------|
| v1 | 배열 (`ecu_version_manifest`) | 없음 |
| v2 | Map (`ecu_version_manifests`) | `custom.operation_result` (deprecated) |
| v3 | Map (`ecu_version_manifests`) | `installation_report` (현재 표준) |

---

## 서버의 manifest 처리 (`ManifestCompiler.scala`)

수신한 manifest로 서버가 하는 일:

```
1. primary_ecu_serial 확인 → 등록된 디바이스인지 검증

2. 서명 검증
   └─ 외부 서명: Primary 공개키 (DB ecus 테이블)
   └─ 내부 서명: 각 ECU 공개키 (DB ecus 테이블)

3. sha256 비교
   installed_image.sha256  ↔  assignments 테이블 sha256
   └─ 일치 → assignment 완료 처리
   └─ 불일치 + installation_report.success=false
        → assignments 초기화
        → generated_metadata_outdated = true (재배포 준비)

4. correlationId → 캠페인 완료 이벤트 발행 (Kafka)
```

핵심 비교 로직:

```scala
// ManifestCompiler.scala
assignment.ecuId == ecuIdentifier &&
  assignmentTarget.filename == installedPath &&         // 파일 이름 일치?
  assignmentTarget.checksum.hash == installedChecksum  // sha256 일치?
```

---

## 로컬에서 확인하는 방법

manifest 자체는 파일로 저장되지 않으므로 sql.db로 동일한 정보를 확인합니다.

```bash
# 현재 설치된 버전 확인
sqlite3 /var/lib/aktualizr/sql.db \
  "SELECT name, sha256, is_current, is_pending, correlation_id FROM installed_versions;"

# 전송 로그 확인
sudo journalctl -u aktualizr | grep -i manifest
```

| 컬럼 | 의미 |
|------|------|
| `is_current = 1` | 현재 활성 버전 (다운로드 완료) |
| `is_pending = 1` | 재부팅 후 적용 예정 (OSTree 전용) |
| `correlation_id` | 연결된 캠페인 ID |
