#!/bin/bash
# push-update.sh — 바이너리 파일을 OTA-CE에 업로드하고 특정 디바이스에 배포
#
# 사용법:
#   bash scripts/push-update.sh <파일경로> <하드웨어ID> <디바이스UUID>
#
# 예시:
#   bash scripts/push-update.sh test-binary.bin jetson-nano af3da729-5b0f-4c30-a2b5-aafaa44114ae

set -euo pipefail

FILE=${1:?"파일 경로를 입력하세요 (예: test-binary.bin)"}
HW_ID=${2:?"하드웨어 ID를 입력하세요 (예: jetson-nano)"}
DEVICE_UUID=${3:?"디바이스 UUID를 입력하세요"}

NAMESPACE="x-ats-namespace:default"
REPOSERVER="reposerver.ota.ce"
DB_CONTAINER="sor_ota_ce-db-1"

NAME=$(basename "$FILE")
SHA256=$(shasum -a 256 "$FILE" | awk '{print $1}')
SIZE=$(wc -c < "$FILE" | tr -d ' ')
VERSION="1.0.0"

echo "=== OTA 업데이트 배포 ==="
echo "파일: $NAME ($SIZE bytes)"
echo "SHA256: $SHA256"
echo "대상 디바이스: $DEVICE_UUID"
echo "하드웨어 ID: $HW_ID"
echo ""

# 1. 바이너리 업로드
echo "[1/4] 바이너리 업로드..."
RESULT=$(curl -s -g -X PUT \
  "http://${REPOSERVER}/api/v1/user_repo/targets/${NAME}?name=${NAME}&version=${VERSION}&hardwareIds=${HW_ID}&length=${SIZE}&checksum%5Bmethod%5D=sha256&checksum%5Bhash%5D=${SHA256}" \
  -H "${NAMESPACE}" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @"${FILE}")

if echo "$RESULT" | grep -qi "error"; then
  echo "업로드 오류: $RESULT"
  exit 1
fi
echo "업로드 완료"

# 2. ECU 시리얼 조회
echo "[2/4] ECU 정보 조회..."
ECU_SERIAL=$(docker exec "$DB_CONTAINER" mysql -uroot -proot director_v2 \
  -se "SELECT ecu_serial FROM ecus WHERE device_id='${DEVICE_UUID}' AND deleted=0 LIMIT 1;" 2>/dev/null | tr -d '\r')

if [ -z "$ECU_SERIAL" ]; then
  echo "오류: 디바이스 UUID '${DEVICE_UUID}'에 등록된 ECU가 없습니다."
  echo "aktualizr를 먼저 실행하여 ECU를 등록하세요."
  exit 1
fi
echo "ECU 시리얼: $ECU_SERIAL"

# 3. ecu_targets ID 조회
echo "[3/4] 타겟 ID 조회..."
TARGET_ID=$(docker exec "$DB_CONTAINER" mysql -uroot -proot director_v2 \
  -se "SELECT id FROM ecu_targets WHERE filename='${NAME}' AND sha256='${SHA256}' ORDER BY created_at DESC LIMIT 1;" 2>/dev/null | tr -d '\r')

if [ -z "$TARGET_ID" ]; then
  echo "오류: ecu_targets에서 타겟을 찾을 수 없습니다."
  exit 1
fi
echo "타겟 ID: $TARGET_ID"

# 4. Assignment 생성 및 메타데이터 재생성 트리거
echo "[4/4] 업데이트 할당..."
CORR_ID="urn:here-ota:campaign:$(uuidgen | tr '[:upper:]' '[:lower:]')"

docker exec "$DB_CONTAINER" mysql -uroot -proot director_v2 -e "
DELETE FROM assignments WHERE device_id='${DEVICE_UUID}' AND ecu_serial='${ECU_SERIAL}';
INSERT INTO assignments (namespace, device_id, ecu_serial, ecu_target_id, correlation_id, in_flight)
VALUES ('default', '${DEVICE_UUID}', '${ECU_SERIAL}', '${TARGET_ID}', '${CORR_ID}', 0);
UPDATE devices SET generated_metadata_outdated=1 WHERE id='${DEVICE_UUID}';" 2>/dev/null

echo ""
echo "=== 배포 완료 ==="
echo "Correlation ID: $CORR_ID"
echo ""
echo "Jetson에서 aktualizr를 실행하면 10초 내로 업데이트를 수신합니다:"
echo "  sudo aktualizr --config /etc/aktualizr/aktualizr.toml --loglevel 0"
