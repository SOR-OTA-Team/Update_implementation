# OTA Update Implementation

**Uptane 기반 OTA 업데이트 구현 — OTA-CE 서버(Mac) + aktualizr(Jetson)**

Mac에서 OTA-CE 서버를 Docker로 실행하고, Jetson Nano(또는 Linux 보드)에 aktualizr를 설치하여  
바이너리 파일을 OTA로 전송하는 전체 구현 과정을 담은 레포지토리입니다.

---

## 전체 흐름

```
[Mac] OTA-CE 서버 (Docker Compose)
   ├── reverse-proxy:80    ← 관리 API (업로드, 디바이스 관리)
   └── gateway:30443       ← 디바이스 전용 (mTLS)
              │
           mTLS 인증
              │
   [Jetson] aktualizr
              │
              ↓
   /var/sota/images/<sha256>  ← 다운로드된 바이너리
```

---

## 디렉토리 구조

```
.
├── README.md
├── docs/
│   ├── full-setup-guide.md                        # 전체 설정 가이드 (단계별) + 캠페인 내부 동작
│   ├── aktualizr-storage-internals.md             # 스토리지 구조, 락, HSM, TOML 설정 상세
│   ├── aktualizr-lowlevel-files-and-atomicity.md  # 저수준 파일, 접근 flow, atomicity
│   └── aktualizr-manifest.md                      # Device Manifest 구조, 전송 시점, director 처리
├── scripts/
│   ├── gen-device-cert.sh          # 디바이스 인증서 생성
│   ├── get-credentials.sh          # credentials.zip 생성
│   └── push-update.sh              # 바이너리 업로드 + 배포 자동화
├── config/
│   ├── aktualizr.toml.template     # aktualizr 설정 템플릿
│   ├── traefik.yml                 # Traefik 정적 설정
│   └── traefik-dynamic.yml         # Traefik 동적 라우팅
└── test-artifacts/                 # 실제 테스트에서 수집한 파일 및 메타데이터
    ├── README.md                   # 파일 사이즈, 내용, 캠페인 vs 메타데이터 비교 정리
    ├── server/
    │   ├── credentials/            # credentials.zip 내용물 (root.json, targets 키 등)
    │   └── tuf-metadata/           # Image Repository TUF 메타데이터 (JSON)
    └── jetson/
        ├── tuf-metadata/           # sql.db에서 추출한 TUF 메타데이터 (JSON)
        ├── import/                 # /var/sota/import/ 인증서 원본
        └── downloaded/             # /var/sota/images/ 다운로드된 바이너리
```

---

## 빠른 시작

### 1. OTA-CE 서버 구동 (Mac)

```bash
# SOR OTA-CE 레포 클론
git clone https://github.com/SOR-OTA-Team/sor_ota_ce.git
cd sor_ota_ce

# 서버 인증서 생성
bash scripts/gen-server-certs.sh

# 서버 실행 (kafka 먼저, 20초 대기 후 나머지)
docker compose -f ota-ce.yaml up db zookeeper kafka -d
# 20초 대기 후
docker compose -f ota-ce.yaml up -d

# 헬스 체크
curl http://director.ota.ce/health
```

### 2. 디바이스 인증서 생성 (Mac)

```bash
bash scripts/gen-device-cert.sh
# → device_uuid.txt, device.key, device.crt 생성
```

### 3. Jetson 설정

```bash
# Mac에서 Jetson으로 파일 전송
scp ota-ce-gen/credentials.zip device.key device.crt \
    ota-ce-gen/devices/ca.crt ota-ce-gen/server_ca.pem \
    <user>@<jetson-ip>:~/

# Jetson에서 설정
sudo mkdir -p /var/sota/import /var/lib/aktualizr /etc/aktualizr
sudo cp ~/device.crt /var/sota/import/client.pem
sudo cp ~/device.key /var/sota/import/pkey.pem
sudo cp ~/server_ca.pem /var/sota/import/root.crt

# /etc/hosts에 Mac IP 추가
echo "<Mac IP>  reposerver.ota.ce keyserver.ota.ce director.ota.ce treehub.ota.ce ota.ce" | sudo tee -a /etc/hosts

# 설정 파일 작성 (config/aktualizr.toml.template 참고)
sudo vi /etc/aktualizr/aktualizr.toml
```

### 4. 바이너리 배포

```bash
# Mac에서
echo "hello OTA world v1" > test.bin
bash scripts/push-update.sh test.bin jetson-nano $(cat ota-ce-gen/device_uuid.txt)
```

### 5. Jetson에서 수신 확인

```bash
sudo aktualizr --config /etc/aktualizr/aktualizr.toml --loglevel 0

# 다운로드 결과
ls /var/sota/images/
```

---

## 참고 레포

- [SOR-OTA-Team/sor_ota_ce](https://github.com/SOR-OTA-Team/sor_ota_ce) — OTA-CE 서버
- [SOR-OTA-Team/sor_aktualizr](https://github.com/SOR-OTA-Team/sor_aktualizr) — aktualizr 클라이언트
