# aktualizr Device Manifest

aktualizr가 서버(director)에 주기적으로 전송하는 업데이트 상태 보고 파일입니다.

---

## 개요

| 항목 | 값 |
|------|-----|
| 전송 방법 | `PUT /director/manifest` (mTLS) |
| 전송 주기 | aktualizr.toml의 `uptane.polling_sec` (기본 10초) |
| 전송 시점 | 최초 실행 시 / 폴링 주기마다 / 업데이트 완료 직후 |
| 크기 (단일 Primary ECU) | 약 600–900B |
| 서명 | Primary ECU의 Uptane 서명 키 (sql.db `primary_keys`) |

---

## 구조

```json
{
  "signatures": [
    {
      "keyid": "<primary Uptane 공개키 ID>",
      "method": "ed25519",
      "sig": "<Base64 서명>"
    }
  ],
  "signed": {
    "primary_ecu_serial": "<ECU serial>",
    "ecu_version_manifests": {
      "<ECU serial>": {
        "signatures": [...],
        "signed": {
          "ecu_serial": "<ECU serial>",
          "installed_image": {
            "filepath": "<target 이름>",
            "fileinfo": {
              "length": <바이트>,
              "hashes": {
                "sha256": "<hex>"
              }
            }
          },
          "attacks_detected": "",
          "report_format": "Json",
          "installation_report": {            ← 설치 후에만 포함
            "result": {
              "success": true,
              "code": "OK",
              "description": ""
            },
            "correlation_id": "urn:here-ota:campaign:<uuid>"
          }
        }
      }
    }
  }
}
```

---

## 버전별 차이

aktualizr는 수신 측(director)이 지원하는 버전을 협상하여 전송합니다.

| 버전 | 변경점 |
|------|--------|
| v1 | `ecu_version_manifest` (배열 형태), `installed_image` 기본 구조 |
| v2 | `operation_result` 필드 추가 (deprecated) |
| v3 | `installation_report` 필드 도입 (현재 표준) |

---

## 이번 테스트에서의 manifest

이번 구현에서는 `aktualizr.toml`에 `[pacman] type = "none"`으로 설정했기 때문에,
바이너리는 `/var/sota/images/<sha256>`에 저장만 되고 **실제 설치를 수행하지 않습니다.**

따라서:
- `installed_image.filepath` = `"test-binary.bin"`
- `installed_image.fileinfo.hashes.sha256` = `"e96547c924dee500a95edd5c44e40606bef4c72431aa3cfcf655645a6b747c8f"`
- `installation_report` = **포함되지 않음** (설치 미수행)
- sql.db `device_installation_result` 테이블 = **비어있음**

> `installed_versions.is_current = 1`은 "다운로드 완료" 상태를 의미하며,
> "설치 완료"와는 다릅니다.

---

## director 수신 처리 (ManifestCompiler.scala)

director는 manifest를 수신하면 다음을 수행합니다.

```
1. Primary ECU 서명 검증 (sql.db primary_keys 공개키 대조)
2. Secondary ECU 서명 검증 (각 ECU 공개키로)
3. installed_image.sha256 ↔ director_v2.assignments sha256 비교
   → 일치: 해당 assignment를 "완료" 처리
   → 불일치 + installation_report.success=false:
       assignments 초기화 + generated_metadata_outdated=1 재설정
4. correlationId 처리 → 캠페인 완료 이벤트 발행 (Kafka)
```

---

## manifest 조회 방법

aktualizr는 manifest를 파일로 저장하지 않습니다.
실시간으로 생성하여 전송한 뒤 메모리에서 해제합니다.

서버 측(director DB)에서 수신된 manifest를 조회하려면:

```sql
-- director DB (MariaDB)
SELECT * FROM device_manifest ORDER BY created_at DESC LIMIT 1;
```

aktualizr 로그에서 전송 시점 확인:

```bash
sudo journalctl -u aktualizr -f | grep -i manifest
# 또는
sudo aktualizr --config /etc/aktualizr/aktualizr.toml --loglevel 0 2>&1 | grep -i manifest
```

---

## 참고: sql.db에서 설치 상태 확인

manifest 대신 로컬 sql.db로 현재 설치 상태를 직접 확인할 수 있습니다.

```bash
sqlite3 /var/lib/aktualizr/sql.db \
  "SELECT name, sha256, is_current, is_pending, correlation_id FROM installed_versions;"
```

| 컬럼 | 의미 |
|------|------|
| `name` | target 이름 (`test-binary.bin`) |
| `sha256` | 파일 해시 |
| `is_current = 1` | 현재 활성 버전 (다운로드 완료) |
| `is_pending = 1` | 재부팅 후 적용 예정 (OSTree 전용) |
| `correlation_id` | 연결된 캠페인 ID |
