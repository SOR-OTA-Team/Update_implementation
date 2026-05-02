# Device Manifest

aktualizr가 director 서버에 전송하는 업데이트 상태 보고입니다.

---

## 목차

| 파일 | 내용 |
|------|------|
| [README.md](README.md) | 개요, 전송 시점, 서명 구조 |
| [structure.md](structure.md) | JSON 필드 상세, 버전별 차이, 소스코드 근거 |
| [examples/](examples/) | 실제 manifest JSON 예시 (v1/v2/v3 + 이번 테스트) |

---

## manifest란?

aktualizr가 director 서버에 **"나 지금 이 파일 설치되어 있어"** 라고 보내는 상태 보고입니다.

- 파일로 저장되지 않습니다
- 전송할 때마다 메모리에서 생성 → PUT 전송 → 해제
- 크기: 단일 Primary ECU 기준 **약 600–900B**

---

## 전송 방식

```
aktualizr (Jetson, Linux)
  │
  │  PUT /manifest  (mTLS, port 30443)
  ▼
director 서버
```

---

## 전송 시점

`sotauptaneclient.cc`에서 확인한 3가지 시점입니다.

| 시점 | 코드 위치 | 설명 |
|------|----------|------|
| 폴링 주기마다 | `checkForUpdates()` 첫 줄 | Uptane Step 1 — 업데이트 확인 **전에** 먼저 전송 |
| 재부팅 후 설치 완료 | `finalizeAfterReboot()` 마지막 | 설치 결과를 포함해 전송 |
| 외부 호출 | `putManifest()` public API | 명시적 요청 시 |

> Uptane 스펙 상 Step 1이 manifest 전송입니다.  
> 서버는 manifest를 받아야 디바이스 상태를 파악하고 다음 단계를 진행합니다.

polling_sec은 `aktualizr.toml`에서 설정합니다 (기본 10초):

```toml
[uptane]
polling_sec = 10
```

---

## 서명 구조

manifest는 **두 겹으로 서명**됩니다.

```
manifest 전체
  └─ signatures[]  ← Primary ECU Uptane 키로 서명
       └─ signed
            └─ ecu_version_manifests
                 └─ 각 ECU manifest
                      └─ signatures[]  ← 해당 ECU 키로 서명
```

서버(director)는 수신 후 두 단계로 검증합니다.

1. `Primary ECU 공개키`로 외부 서명 검증
2. 각 ECU 공개키로 내부 ECU manifest 서명 검증

---

## Primary vs Secondary ECU

| | Primary (aktualizr, Linux) | Secondary (RTOS ECU) |
|---|---|---|
| OS | Linux (Ubuntu, L4T 등) | RTOS (FreeRTOS, AUTOSAR 등) |
| 서버 통신 | 직접 PUT | Primary 통해 간접 전달 |
| manifest | 직접 생성·서명·전송 | Primary가 대신 포함해서 전송 |
| 업데이트 수신 | 서버에서 직접 다운로드 | Primary로부터 전달받음 |

이번 테스트는 Jetson이 Primary이고 Secondary ECU 없는 단독 구성입니다.
