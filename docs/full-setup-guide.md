# 전체 설정 가이드

Mac에서 OTA-CE 서버를 실행하고 Jetson에 aktualizr를 설치하여  
바이너리 OTA 업데이트를 수행하는 전체 과정입니다.

---

## 사전 요구사항

| 항목 | 요구사항 |
|------|----------|
| Mac | Docker Desktop 실행 중, 메모리 4GB 이상 할당 |
| Jetson | Ubuntu 기반, aktualizr 설치됨 |
| 네트워크 | Mac과 Jetson이 같은 LAN |

---

## Step 1. OTA-CE 서버 구동 (Mac)

### 1-1. 레포 클론 및 서버 인증서 생성

```bash
git clone https://github.com/SOR-OTA-Team/sor_ota_ce.git
cd sor_ota_ce
bash scripts/gen-server-certs.sh
```

`ota-ce-gen/` 디렉토리에 서버 인증서가 생성됩니다.

### 1-2. /etc/hosts 설정

```bash
sudo bash -c 'echo "127.0.0.1  reposerver.ota.ce keyserver.ota.ce director.ota.ce treehub.ota.ce deviceregistry.ota.ce campaigner.ota.ce ota.ce" >> /etc/hosts'
```

### 1-3. 서버 실행

**반드시 아래 순서를 지켜야 합니다.** kafka가 먼저 올라와야 ota-lith가 정상 기동됩니다.

```bash
# 1단계: DB, zookeeper, kafka 먼저 실행
docker compose -f ota-ce.yaml up db zookeeper kafka -d
```

20초 대기 후:

```bash
# 2단계: 나머지 전체 실행
docker compose -f ota-ce.yaml up -d
```

> **주의**: kafka 없이 `up -d`를 바로 실행하면 ota-lith가  
> `No resolvable bootstrap urls given in bootstrap.servers` 오류로 실패하고  
> 헬스 체크에서 Bad Gateway가 반환됩니다.

### 1-4. 헬스 체크

```bash
curl http://director.ota.ce/health    # {"status":"OK"}
curl http://reposerver.ota.ce/health  # {"status":"OK"}
```

헬스 체크가 실패하면 로그 확인:

```bash
docker compose -f ota-ce.yaml logs ota-lith --tail 30
```

### 1-5. credentials.zip 생성

```bash
bash scripts/get-credentials.sh
# → ota-ce-gen/credentials.zip 생성
```

---

## Step 2. 디바이스 인증서 생성 (Mac)

```bash
bash scripts/gen-device-cert.sh
```

생성 파일:
- `ota-ce-gen/device_uuid.txt` — 디바이스 UUID
- `ota-ce-gen/device.key` — 개인키
- `ota-ce-gen/device.crt` — 클라이언트 인증서 (device CA로 서명)

---

## Step 3. Jetson 설정

### 3-1. Mac에서 파일 전송

```bash
JETSON_USER="caucps2"
JETSON_IP="192.168.0.154"

scp ota-ce-gen/credentials.zip \
    ota-ce-gen/device.key \
    ota-ce-gen/device.crt \
    ota-ce-gen/devices/ca.crt \
    ota-ce-gen/server_ca.pem \
    ${JETSON_USER}@${JETSON_IP}:~/
```

### 3-2. Jetson에서 인증서 배치

```bash
sudo mkdir -p /var/sota/import /var/lib/aktualizr /etc/aktualizr

sudo cp ~/device.crt /var/sota/import/client.pem
sudo cp ~/device.key /var/sota/import/pkey.pem
sudo cp ~/server_ca.pem /var/sota/import/root.crt

# 확인
sudo head -1 /var/sota/import/client.pem   # -----BEGIN CERTIFICATE-----
sudo head -1 /var/sota/import/pkey.pem     # -----BEGIN PRIVATE KEY-----
```

### 3-3. Jetson의 /etc/hosts 설정

Mac IP 확인 (Mac 터미널에서):
```bash
ifconfig | grep "inet " | grep -v 127
```

Jetson에서:
```bash
MAC_IP="192.168.0.147"  # 실제 Mac IP로 변경
sudo bash -c "echo '${MAC_IP}  reposerver.ota.ce keyserver.ota.ce director.ota.ce treehub.ota.ce ota.ce' >> /etc/hosts"

# 연결 확인
curl http://reposerver.ota.ce/health
```

### 3-4. aktualizr 설정 파일 작성

`config/aktualizr.toml.template`을 참고하여 작성합니다.

```bash
# Jetson에서
DEVICE_UUID=$(cat ~/device_uuid.txt 2>/dev/null || echo "<Mac에서 cat ota-ce-gen/device_uuid.txt 결과>")
sudo vi /etc/aktualizr/aktualizr.toml
```

---

## Step 4. 디바이스 등록 (Mac)

aktualizr 최초 실행 전에 device registry에 등록합니다.

```bash
DEVICE_UUID=$(cat ota-ce-gen/device_uuid.txt)

curl -s -X POST "http://deviceregistry.ota.ce/api/v1/devices" \
  -H "x-ats-namespace:default" \
  -H "Content-Type: application/json" \
  -d "{\"deviceName\":\"jetson-nano\",\"deviceId\":\"${DEVICE_UUID}\",\"deviceType\":\"Other\"}"
```

---

## Step 5. aktualizr 실행 (Jetson)

```bash
sudo aktualizr --config /etc/aktualizr/aktualizr.toml --loglevel 0
```

정상 연결 시 로그:
```
SSL certificate verify ok
Successfully imported client certificate
provisioned OK
```

---

## Step 6. 바이너리 업로드 및 배포 (Mac)

```bash
# 테스트 파일 생성
echo "hello OTA world v1" > test-binary.bin

# 업로드 + 배포 (스크립트 사용)
bash scripts/push-update.sh test-binary.bin jetson-nano $(cat ota-ce-gen/device_uuid.txt)
```

---

## 캠페인(Assignment) 내부 동작 상세

`push-update.sh`가 수행하는 4단계의 내부 동작을 자세히 설명합니다.

### 왜 공식 API를 쓰지 않는가

OTA-CE의 campaigner 서비스는 캠페인 생성 API(`POST /api/v1/campaigns`)를 제공하지만,
이 엔드포인트는 실제로 `director_v2` DB의 assignment 레코드를 자동으로 생성하지 않습니다.
director가 타겟을 특정 디바이스에게 서명하려면 `assignments` 테이블에 레코드가 있어야 하므로,
**DB에 직접 삽입**하는 방식을 사용합니다.

### Step 6-1. 바이너리 업로드 (Image Repository)

```bash
curl -g -X PUT \
  "http://reposerver.ota.ce/api/v1/user_repo/targets/<파일명>?name=<파일명>&version=1.0.0&hardwareIds=jetson-nano&length=<SIZE>&checksum%5Bmethod%5D=sha256&checksum%5Bhash%5D=<SHA256>" \
  -H "x-ats-namespace:default" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @<파일>
```

- reposerver(Image Repository)에 바이너리 원본을 저장합니다.
- `hardwareIds`로 어떤 하드웨어 타입에 적용 가능한지 태깅합니다.
- 업로드 성공 시 `director_v2.ecu_targets` 테이블에 파일 메타데이터(filename, sha256, length)가 자동으로 기록됩니다.
- **URL에서 `[`, `]`는 반드시 `%5B`, `%5D`로 인코딩하거나 `-g` 플래그를 사용해야 합니다.** 그렇지 않으면 curl이 배열 범위로 해석하여 오류가 발생합니다.

### Step 6-2. ECU 시리얼 조회

```bash
docker exec sor_ota_ce-db-1 mysql -uroot -proot director_v2 \
  -se "SELECT ecu_serial FROM ecus WHERE device_id='<DEVICE_UUID>' AND deleted=0 LIMIT 1;"
```

- aktualizr가 최초 실행될 때 `/director/ecus` 엔드포인트로 자신의 ECU 정보를 등록합니다.
- `ecus` 테이블에는 `device_id`(= Device UUID)와 `ecu_serial`(aktualizr가 생성한 고유값)이 매핑되어 있습니다.
- assignment는 device 단위가 아니라 **ECU 단위**로 생성되므로 이 시리얼이 필요합니다.
- aktualizr를 아직 한 번도 실행하지 않은 경우 이 테이블에 레코드가 없으므로 Step 5를 먼저 실행해야 합니다.

### Step 6-3. ecu_targets ID 조회

```bash
docker exec sor_ota_ce-db-1 mysql -uroot -proot director_v2 \
  -se "SELECT id FROM ecu_targets WHERE filename='<파일명>' AND sha256='<SHA256>' ORDER BY created_at DESC LIMIT 1;"
```

- Step 6-1에서 업로드한 파일의 DB 레코드 ID를 가져옵니다.
- `assignments` 테이블이 파일을 직접 참조하는 것이 아니라 `ecu_targets.id`를 외래키로 사용하기 때문입니다.

### Step 6-4. Assignment 삽입 및 메타데이터 갱신 트리거

```bash
docker exec sor_ota_ce-db-1 mysql -uroot -proot director_v2 -e "
DELETE FROM assignments WHERE device_id='<UUID>' AND ecu_serial='<ECU_SERIAL>';
INSERT INTO assignments (namespace, device_id, ecu_serial, ecu_target_id, correlation_id, in_flight)
VALUES ('default', '<UUID>', '<ECU_SERIAL>', '<TARGET_ID>', 'urn:here-ota:campaign:<uuid>', 0);
UPDATE devices SET generated_metadata_outdated=1 WHERE id='<UUID>';"
```

각 쿼리의 역할:

| 쿼리 | 목적 |
|------|------|
| `DELETE FROM assignments` | 기존 할당을 제거하여 중복 방지 |
| `INSERT INTO assignments` | ECU에 새 타겟을 할당 |
| `UPDATE devices SET generated_metadata_outdated=1` | director에게 TUF 메타데이터 재서명 요청 |

**`generated_metadata_outdated` 플래그가 핵심입니다.**

director는 디바이스별 `targets.json`을 매번 새로 서명하지 않고, 이전에 서명된 결과를 `device_roles` 테이블에 캐싱해둡니다. aktualizr가 manifest를 전송하면 director는 이 플래그를 확인하여:

```
generated_metadata_outdated = 0  →  device_roles 캐시를 그대로 전송 (No new updates found)
generated_metadata_outdated = 1  →  assignments를 재조회하여 targets.json 재서명 후 전송
```

즉, assignment를 삽입해도 이 플래그를 세우지 않으면 aktualizr는 업데이트를 인식하지 못합니다.

**`correlation_id` 형식 주의:**

```
올바른 형식: urn:here-ota:campaign:550e8400-e29b-41d4-a716-446655440000
잘못된 형식: test-campaign-001  ← director가 Invalid correlationId 오류 반환
```

### 전체 캠페인 흐름 요약

```
[Mac] push-update.sh
  │
  ├─ [1] PUT /api/v1/user_repo/targets/<파일>   → reposerver에 바이너리 저장
  │                                               director_v2.ecu_targets에 메타데이터 기록
  │
  ├─ [2] SELECT ecus WHERE device_id=...         → ECU 시리얼 조회
  │
  ├─ [3] SELECT ecu_targets WHERE filename=...   → 타겟 ID 조회
  │
  └─ [4] INSERT assignments + UPDATE devices(outdated=1)
           │
           │  (aktualizr polling_sec 간격으로 폴링)
           ▼
[Jetson] aktualizr
  │
  ├─ PUT /director/manifest  →  director가 outdated 플래그 확인
  │                              assignments 재조회 → targets.json 재서명
  │                              device_roles 캐시 갱신, outdated=0으로 리셋
  │
  ├─ GET /director/targets.json  (디바이스 전용, 서명된 타겟 목록)
  ├─ GET /repo/targets.json      (Image Repository, 전체 공개)
  │   └─ 두 targets.json의 sha256 해시 일치 검증 (Uptane 이중 검증)
  │
  └─ GET /repo/targets/<파일>    →  /var/sota/images/<SHA256>에 저장
```

---

## Step 7. 업데이트 수신 확인 (Jetson)

```bash
sudo aktualizr --config /etc/aktualizr/aktualizr.toml --loglevel 0 2>&1 | \
  grep -i "EcuDownload\|EcuInstall"
```

성공 시:
```
"id" : "EcuDownloadStarted"
"id" : "EcuDownloadCompleted"   ← success: true
"id" : "EcuInstallationStarted"
"id" : "EcuInstallationCompleted"  ← success: true
```

다운로드된 파일 확인:
```bash
ls /var/sota/images/
cat /var/sota/images/<SHA256_HASH>
# hello OTA world v1
```

---

## 트러블슈팅

| 에러 | 원인 | 해결 |
|------|------|------|
| `Couldn't resolve host: ota.ce` | /etc/hosts 줄바꿈 오류 | `cat /etc/hosts`로 한 줄인지 확인 |
| `Could not parse certificate` | client.pem이 개인키 | `head -1`로 CERTIFICATE 확인 후 재복사 |
| `No new updates found` | director 메타데이터 미갱신 | `generated_metadata_outdated=1` 설정 (push-update.sh가 자동 처리) |
| `SSL certificate problem` | system_info 리다이렉트 | 무시 가능, 업데이트에 영향 없음 |
| `missing_device` | device registry 미등록 | Step 4 실행 |
| `Client certificate not found` | 인증서 파일 누락/불일치 | /var/sota/import/ 파일 재확인 |
| `Invalid correlationId` | 잘못된 형식 | `urn:here-ota:campaign:<uuid>` 형식 사용 |

---

## 주요 개념

### Uptane 이중 검증

aktualizr는 업데이트를 수신할 때 두 저장소를 모두 확인합니다:

```
Director Repository     Image Repository
(어떤 ECU에 무엇을)     (파일 실제 내용)
        ↓                      ↓
    targets.json           targets.json
    (디바이스별)           (전체 공개)
        └──── 해시 일치 검증 ────┘
                    ↓
              다운로드 진행
```

### mTLS 인증 흐름

```
aktualizr                    gateway (nginx)
    │                              │
    │── TLS 연결 시도 ────────────▶│
    │   (client.pem 제시)         │
    │                              │── devices/ca.crt로 검증
    │◀── 연결 수락 ───────────────│
    │    (CN = Device UUID)        │── CN을 deviceUuid로 사용
    │                              │
    │── PUT /director/manifest ──▶│── /api/v1/device/{uuid}/manifest
```

### 파일 저장 위치

```
Jetson /var/sota/
├── import/
│   ├── client.pem    ← 디바이스 클라이언트 인증서
│   ├── pkey.pem      ← 디바이스 개인키
│   └── root.crt      ← 서버 CA 인증서
└── images/
    └── <SHA256>      ← 다운로드된 바이너리 (해시 이름으로 저장)
```
