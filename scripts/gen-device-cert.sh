#!/bin/bash
# gen-device-cert.sh — 디바이스 클라이언트 인증서 생성
#
# 사용법:
#   bash scripts/gen-device-cert.sh
#
# 생성 파일:
#   ota-ce-gen/device_uuid.txt  — 디바이스 UUID
#   ota-ce-gen/device.key       — 개인키
#   ota-ce-gen/device.crt       — 클라이언트 인증서 (device CA로 서명)

set -euo pipefail

SERVER_DIR=ota-ce-gen

if [ ! -f "${SERVER_DIR}/devices/ca.crt" ] || [ ! -f "${SERVER_DIR}/devices/ca.key" ]; then
  echo "오류: ${SERVER_DIR}/devices/ca.crt 또는 ca.key 가 없습니다."
  echo "먼저 bash scripts/gen-server-certs.sh 를 실행하세요."
  exit 1
fi

DEVICE_UUID=$(uuidgen | tr '[:upper:]' '[:lower:]')
echo "Device UUID: $DEVICE_UUID"

openssl genrsa -out "${SERVER_DIR}/device.key" 2048
openssl req -new -key "${SERVER_DIR}/device.key" -subj "/CN=${DEVICE_UUID}" -out "${SERVER_DIR}/device.csr"
openssl x509 -req \
  -in "${SERVER_DIR}/device.csr" \
  -CA "${SERVER_DIR}/devices/ca.crt" \
  -CAkey "${SERVER_DIR}/devices/ca.key" \
  -CAcreateserial \
  -out "${SERVER_DIR}/device.crt" \
  -days 36500

rm -f "${SERVER_DIR}/device.csr"

echo "$DEVICE_UUID" > "${SERVER_DIR}/device_uuid.txt"

echo ""
echo "=== 생성 완료 ==="
echo "UUID: $DEVICE_UUID"
echo "파일:"
echo "  ${SERVER_DIR}/device_uuid.txt"
echo "  ${SERVER_DIR}/device.key"
echo "  ${SERVER_DIR}/device.crt"
echo ""
echo "인증서 확인:"
openssl x509 -in "${SERVER_DIR}/device.crt" -noout -subject -dates
