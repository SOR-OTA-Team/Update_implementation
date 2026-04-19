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

```bash
docker compose -f ota-ce.yaml up db -d
sleep 15
docker compose -f ota-ce.yaml up -d
```

### 1-4. 헬스 체크

```bash
curl http://director.ota.ce/health    # {"status":"OK"}
curl http://reposerver.ota.ce/health  # {"status":"OK"}
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
