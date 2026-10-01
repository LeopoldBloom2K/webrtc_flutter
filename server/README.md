# VoiceGuard Server

시그널링과 세션 관리를 한 프로세스에서 처리한다. (기존 `server.js` 대체)

## 실행

**Python 3.11 이상이 필요합니다.**

```bash
conda create -n voiceguard python=3.11 -y && conda activate voiceguard
cd server
pip install -r requirements.txt
python main.py                 # 0.0.0.0:8080
```

VocalCrypt 알고리즘은 레포 루트의 `vocalCrypt/vocalcrypt_v3.py`(A파트 원본)를
직접 불러 쓴다. 서버 쪽에 복사본이 없으므로 A파트가 원본을 고치면 서버 재시작만으로
통화 경로에 반영된다. 기동 로그의 `VocalCrypt 원본 연결: … (수정 MM-DD HH:MM)` 줄로
어느 판이 들어갔는지 확인할 수 있다. 그래서 `server/` 만 따로 떼어 배포하면 안 되고,
`vocalCrypt/` 가 `server/` 와 같은 레벨에 있어야 한다.

### 왜 3.11 이상인가

scipy 1.15.x 는 macOS 27 에서 기동하지 못합니다. `_propack` 확장의 Mach-O
바이너리에 `__DATA/__thread_bss` 가 zero-fill 인데 offset 필드가 0 이 아니라
dyld 가 거부합니다. scipy 1.16.0 부터 고쳐졌고, 1.16 은 Python 3.11 이상을
요구합니다.

`scipy.io` 를 안 쓰더라도 **`scipy.signal` 이 `scipy.linalg` →
`scipy.sparse` → `_propack` 을 끌어옵니다**(`scipy/linalg/_sketches.py`).
그래서 WAV 입출력을 자체 구현으로 바꿔도 이 제약은 남습니다.

Android 에뮬레이터에서는 `ws://10.0.2.2:8080` 으로 접속한다. (기존과 동일)

## 기기/에뮬레이터 확인

앱이 실제로 마이크에서 녹음해 보호본을 받아오는지가 가장 먼저 되어야 한다.
녹음 자체는 이미 구현되어 있다(`record` 패키지, `RECORD_AUDIO` 권한,
`webrtc_manager.captureAndProtect()`). 막혀 있는 건 아래 두 줄이다.

### Flutter 에서 고칠 것

| 파일 | 줄 | 지금 | 바꿀 값 | 이유 |
|---|---|---|---|---|
| `lib/vocalcrypt_service.dart` | 36 | `http://10.0.2.2:8765` | `http://10.0.2.2:8080` | 서버가 통합됨 |
| `lib/call_screen.dart` | 68 | `http://10.0.2.2:8765` | `http://10.0.2.2:8080` | 같음 |
| `lib/webrtc_manager.dart` | 231 | `sampleRate: 48000` | `sampleRate: 16000` | 아래 참조 |

**48kHz 로 녹음할 이유가 없다.** 주입되는 노이즈의 99.9% 가 4kHz 이하라
48kHz 로 올려도 20kHz 대역은 보호가 전혀 없고, 데이터와 처리 비용만 3배가
된다(3초 기준 71ms → 193ms). 탐지 특징과 보정도 16kHz 기준이다.

### 확인 절차

1. 서버 기동 — `cd server && python3 main.py`
2. 서버만 먼저 점검 — `bash scripts/check_device_path.sh`
   앱이 보내는 것과 같은 요청(3초 모노 WAV, multipart)을 재현해
   실측 SNR 까지 확인한다.
3. 에뮬레이터 마이크 켜기 — AVD 설정에서 마이크를 호스트 입력으로 연결하거나,
   오디오 파일을 마이크 입력으로 주입한다. 후자는 재현 가능한 테스트가 된다.
4. 앱에서 보호 실행 → 로그의 `[VocalCrypt] done` 과 서버 로그의
   `목표 22.0dB / 실측 21.8dB` 가 맞는지 대조한다.

### `/protect` 응답 헤더

기기에서 보호가 실제로 됐는지 앱이 따로 계산하지 않고 확인할 수 있도록
측정값을 헤더로 돌려준다.

| 헤더 | 내용 |
|---|---|
| `X-Measured-Snr` | 실측 SNR(dB). 목표값과 크게 다르면 처리가 제대로 안 된 것 |
| `X-Processing-Ms` | 서버 처리 시간 |
| `X-Sample-Rate` | 서버가 인식한 샘플레이트 |
| `X-Audio-Seconds` | 오디오 길이 |

## 배포

### 설정 (환경변수)

로컬에서는 아무것도 설정하지 않아도 지금까지와 똑같이 돈다.
배포에서는 **최소한 `VOICEGUARD_AUTH_TOKEN` 을 설정해야 한다.**

| 변수 | 기본 | 설명 |
|---|---|---|
| `VOICEGUARD_AUTH_TOKEN` | (없음) | 공유 토큰. 비어 있으면 **인증하지 않는다** |
| `VOICEGUARD_HOST` / `VOICEGUARD_PORT` | `0.0.0.0` / `8080` | bind |
| `VOICEGUARD_ALLOWED_ORIGINS` | (없음) | 쉼표 구분 CORS 출처 |
| `VOICEGUARD_MAX_UPLOAD_MB` | 32 | 업로드 상한 |
| `VOICEGUARD_MAX_FRAME_MB` | 4 | 오디오 프레임 상한 |
| `VOICEGUARD_THREADS` | CPU 수(최대 8) | 무거운 연산용 스레드 수 |
| `VOICEGUARD_LOG_LEVEL` | `INFO` | 로그 수준 |

인증 방법: HTTP 는 `Authorization: Bearer <token>`, WebSocket 은
`?token=<token>` 또는 같은 헤더. `/health` 만 토큰 없이 응답한다(상태 점검용).

### ⚠ 워커는 반드시 1개

**세션 상태가 프로세스 메모리에 있다.** 워커를 늘리면 1번 워커에서 만든
세션을 2번 워커가 모르고, `/detect` 가 404 를 낸다. `main.py` 는 `workers=1`
로 고정되어 있으니 `uvicorn --workers N` 이나 gunicorn 다중 워커로 띄우지 말 것.

수평 확장이 필요해지면 세션을 외부 저장소(Redis 등)로 빼야 한다. 그 전까지는
단일 프로세스 + 스레드풀로 처리한다.

### TLS

앱은 `wss://` 로 붙어야 한다. 서버가 직접 TLS 를 하지 않고 앞단에서 종단한다.

```nginx
location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;      # WebSocket 필수
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_read_timeout 3600s;                    # 통화 중 끊기지 않게
}
```

`proxy_read_timeout` 을 늘리지 않으면 통화 중 시그널링이 끊긴다.

### 실행

```bash
export VOICEGUARD_AUTH_TOKEN="$(openssl rand -hex 32)"
python3 main.py
```

### Flutter 쪽 대응

| 파일 | 지금 | 배포 |
|---|---|---|
| `screens/call_main_screen.dart` | `ws://10.0.2.2:8080` | `wss://<host>?token=<T>` |
| `vocalcrypt_service.dart` | `http://10.0.2.2:8765` | `https://<host>` + Bearer |
| `call_screen.dart` | `http://10.0.2.2:8765` | 같음 |

### 아직 없는 것

공유 토큰은 "앱을 쓰는 클라이언트인가"만 증명한다. **누가** 쓰는지는 증명하지
않으므로 계정 단위 대응(신고·차단·신규 계정 제한)에는 부족하다. 사용자 인증,
요청 속도 제한, 세션 외부 저장소는 별도 작업이다.

## 검증

```bash
bash tests/run_all.sh        # 전체

python3 tests/test_signaling.py
```

프로토콜 호환성, 세션 격리, 종료 처리 19개 항목을 확인한다.

## 엔드포인트

| | 경로 | 용도 |
|---|---|---|
| WS | `/` | 시그널링 |
| WS | `/audio` | 통화 음성 중계 — 내 마이크를 보호해 상대방에게 전달 |
| POST | `/protect` | WAV 한 개 VocalCrypt 처리 (기존 `:8765` 계약과 동일) |
| POST | `/detect` | 청크 채점 + 세션 누적 상태 갱신 |
| GET | `/health` | 상태 |

## 프로토콜

클라이언트 → 서버 (기존 8종, 변경 없음)

| type | 필드 |
|---|---|
| `call_request` / `call_accept` / `call_reject` / `call_cancel` / `hang_up` | — |
| `offer` / `answer` | `sdp` |
| `ice` | `candidate`, `sdpMid`, `sdpMLineIndex` |

서버 → 클라이언트 (추가분)

| type | 필드 | 시점 |
|---|---|---|
| `session_start` | `session_id`, `role` (`caller`/`callee`) | `call_accept` 성립 시 |
| `session_end` | `session_id`, `reason` | 통화 종료 / 상대 연결 끊김 |

기존 클라이언트는 모르는 `type` 을 무시하므로 하위 호환된다.

## 통화 음성 중계 (`/audio`)

통화 음성은 WebRTC 를 거치지 않고 이 채널로 오간다. 상대방이 듣는 소리는
언제나 서버에서 VocalCrypt 가 적용된 음성이다.

```
폰A 마이크 ─PCM16─▶ /audio(caller) ─VocalCrypt─▶ /audio(callee) ─▶ 폰B 스피커
폰B 마이크 ─PCM16─▶ /audio(callee) ─VocalCrypt─▶ /audio(caller) ─▶ 폰A 스피커
```

1. 시그널링에서 `session_start` 를 받은 양쪽이 각자 `/audio` 에 접속한다.
   첫 프레임은 텍스트(JSON) 핸드셰이크

   ```json
   {"session_id": "...", "role": "caller", "sample_rate": 16000, "target_snr": 22.0}
   ```

   서버가 `{"type":"audio_ready", ...}` 로 답한다. `session_id` 가 유효하지
   않으면 1008, `role` 이 `caller`/`callee` 가 아니면 1003 으로 닫힌다.

2. 이후 **내가 보내는** 바이너리 프레임 = 내 마이크, 16-bit little-endian PCM 모노.
   **내가 받는** 바이너리 프레임 = 상대방의 보호된 음성, 같은 형식.
   상대 채널이 아직 열리지 않았으면 그 사이 프레임은 버린다(연결 직후의 짧은 구간).

3. 앱(`lib/audio_relay.dart`)은 100ms 단위로 보낸다. 서버는 2초마다 방향별로
   입력 RMS/peak·출력 RMS·프레임당 처리 시간을 로그에 남긴다. 입력의 peak 와
   RMS 차이(crest factor)가 3~4dB 면 목소리가 아니라 연속 톤이 들어오는 것이다.

무거운 연산은 `asyncio.to_thread` 로 넘겨서 시그널링 WebSocket 을 막지 않는다.

### 실측 (`tests/test_relay.py`, 가상 폰 2대가 실시간 속도로 동시에 송신)

| 항목 | 값 |
|---|---|
| 라우팅 | 받은 음성 vs 상대 원음 상관 0.997, vs 자기 원음 0.00 |
| 보호 SNR | A→B 21.6dB, B→A 21.9dB (목표 22dB) |
| 누락 | 60/60 프레임, 샘플 수 일치 |
| 서버 구간 지연 | 중앙값 47ms, p95 50ms, 6초 동안 누적 없음 |

단방향 프레임 처리는 100ms 프레임에서 15ms 안팎(RTF 0.15)이다. 양방향이 동시에
처리되면 프레임당 시간이 늘지만 실시간 여유는 충분하다. 기기 성능에 따라 다시 재야
한다. `tests/test_audio.py` 가 청크 길이별 표를 출력한다.

**알고리즘상 제약**: 청크마다 F0 를 새로 추정하고 피크 정규화를 다시 하므로
청크 경계에서 노이즈 성분이 불연속이 된다. 100ms 에서 경계 점프가 청크 내부의
약 2.4배(신호 대비 약 -32dB), 20ms 에서 5.5배다. 상태 유지형으로 바꾸려면 A파트
알고리즘 수정이 필요하다.

## 탐지 (`/detect`)

학습 없이 계산으로만 판별한다. 청크 하나로 이진 판정을 내리지 않고,
점수를 세션에 누적해 상태로만 노출한다.

```
요청  multipart/form-data   file=<WAV 청크>, session_id=..., role=caller|callee
응답  {"p_spoof":0.31, "state":"human", "window_mean":0.28, "chunks":12,
       "calibrated":false, "features":{...}, "latency_ms":12.4}
```

상태는 `analyzing` → `human` / `ai_suspected` / `ai_detected` 로 바뀐다.
창이 차기 전에는 `analyzing`, 확정(`ai_detected`)은 되돌리지 않는다.
`role` 별로 누적이 분리된다.

### 쓰는 특징 (`detect/features.py`)

| 특징 | 근거 |
|---|---|
| jitter / shimmer | 자연 발화는 주기·진폭이 미세하게 흔들린다. 합성음은 과하게 규칙적 |
| HNR | 비주기(기식·마찰) 성분의 양 |
| 고역 비율 / 평탄도 / 기울기 | 보코더가 고역을 부자연스럽게 자르는지 |

## 임계값 보정 (`detect/calibrate.py`)

라벨된 음성으로 운영 임계값을 계산한다. 학습이 아니라 통계 + 탐색이다.

```bash
python3 -m detect.calibrate --bonafide data/real --spoof data/fake \
                            --out detect/calibration.json
```

`detect/calibration.json` 이 생기면 `SignalScorer` 와 `Track` 이 자동으로
그 값을 쓰고 응답의 `calibrated` 가 `true` 가 된다. 파일이 없으면 임시값으로 돈다.

### 무엇을 계산하나

| 단계 | 방법 | 이유 |
|---|---|---|
| 특징별 방향·가중치 | AUC | 손으로 정한 방향이 틀리면 그 특징이 점수를 반대로 끌어내린다 |
| EER | **이분 탐색** | FAR−FRR 이 임계값에 대해 단조이므로 교차점을 O(log n) 에 찾는다 |
| 청크 오탐 1% 지점 | **이분 탐색** | 오탐율이 임계값에 대해 단조 |
| `suspect_at` / `detect_at` | **이분 탐색** + 통화 모의 | 경보율이 임계값에 대해 단조 |

임계값 탐색이 이분 탐색인 이유는 대상 함수가 단조이기 때문이다. 격자 탐색과
달리 해상도를 O(log n) 으로 올릴 수 있고 경계에서 튀지 않는다.

### 설계상 지킨 것

- **파일 단위 분할.** 특징 파라미터는 절반으로 정하고 EER 은 나머지 절반에서
  잰다. 청크 단위로 나누면 같은 파일이 양쪽에 걸쳐 성능이 과대평가된다.
- **통화 단위 목표.** 사용자가 겪는 것은 "정상 통화 3분에 경고가 떴는가"이지
  청크 하나가 아니다. 상태 임계값은 통화 모의 위에서 잡는다.
- **연속 구간 추출.** 통화를 모의할 때 같은 파일의 연속 구간을 뽑는다. 청크를
  iid 로 섞으면 오경보율이 실제보다 낙관적으로 나온다.
- **부트스트랩 신뢰구간.** 표본이 적으면 EER 차이는 의미가 없다.
- **자기 진단.** 데이터가 질문을 감당하지 못하면 결과 대신 경고를 낸다
  (파일이 통화보다 짧음, 파일 수 부족, EER 이 비현실적으로 낮음 등).

### 필요한 데이터

- bonafide / spoof 각각 **20개 파일 이상**
- 파일 길이는 **통화 길이 이상** 권장 (`--call-seconds` 기본 180초).
  짧으면 한 파일이 통화 전체를 지배해 오경보 추정이 무의미해진다.
- 실제 통화 조건(Opus 통과, 잡음)을 거친 음성이어야 한다.

### ⚠ 임계값이 아직 보정되지 않았다

`detect/scorer.py` 의 `THRESHOLDS` 는 **임시값**이다. 현재 상태로 재보면
자연 발화 근사 신호도 `p_spoof ≈ 0.62` 가 나와 `suspect_at=0.60` 을 넘는다.
즉 지금 그대로 쓰면 정상 통화가 전부 의심으로 뜬다.

보정 절차:

1. 실제 한국어 통화 음성과 합성 음성 각각에서 특징 분포를 측정
2. 고정 오탐율(정상 통화 3분에 1% 등) 지점에서 임계값을 잡는다
3. `Track` 의 `window` / `suspect_at` / `detect_at` / `hold_chunks` 를 그 분포로 다시 정한다

응답의 `calibrated: false` 가 이 상태를 표시한다. 보정 전까지 점수의
절대값은 의미가 없고, 파이프라인 동작 확인 용도로만 쓴다.

판별기는 `detect/scorer.py` 의 `Scorer` 프로토콜로 교체 가능하다.

## 기존 `server.js` 대비 변경

- **세션 격리** — 통화가 성립하면 두 피어 사이에서만 중계한다.
  기존에는 접속한 전원에게 브로드캐스트되어 제3자가 SDP 를 볼 수 있었다.
- **세션 식별자** — `/detect` 가 "어느 통화의 어느 방향인지" 알 수 있도록 ID 를 발급한다.
- **연결 종료 처리** — 한쪽이 끊기면 상대에게 `hang_up` + `session_end` 를 보낸다.

## 알려진 한계

- `call_request` 는 주소 지정이 없어 로비 전체에 전달된다. 통화가 성립하기 전까지는
  제3자도 "누가 전화를 걸고 있다"는 사실을 안다. 연락처 기반 주소 지정이 들어가야 해소된다.
- 인증 없음. `ws://` 평문. 로컬 데모 기준이며 배포 시 `wss://` 와 인증이 필요하다.

## 기기/에뮬레이터 확인

앱이 실제로 마이크에서 녹음해 보호본을 받아오는지가 가장 먼저 되어야 한다.
녹음 자체는 이미 구현되어 있다(`record` 패키지, `RECORD_AUDIO` 권한,
`webrtc_manager.captureAndProtect()`). 막혀 있는 건 아래 두 줄이다.

### Flutter 에서 고칠 것

| 파일 | 줄 | 지금 | 바꿀 값 | 이유 |
|---|---|---|---|---|
| `lib/vocalcrypt_service.dart` | 36 | `http://10.0.2.2:8765` | `http://10.0.2.2:8080` | 서버가 통합됨 |
| `lib/call_screen.dart` | 68 | `http://10.0.2.2:8765` | `http://10.0.2.2:8080` | 같음 |
| `lib/webrtc_manager.dart` | 231 | `sampleRate: 48000` | `sampleRate: 16000` | 아래 참조 |

**48kHz 로 녹음할 이유가 없다.** 주입되는 노이즈의 99.9% 가 4kHz 이하라
48kHz 로 올려도 20kHz 대역은 보호가 전혀 없고, 데이터와 처리 비용만 3배가
된다(3초 기준 71ms → 193ms). 탐지 특징과 보정도 16kHz 기준이다.

### 확인 절차

1. 서버 기동 — `cd server && python3 main.py`
2. 서버만 먼저 점검 — `bash scripts/check_device_path.sh`
   앱이 보내는 것과 같은 요청(3초 모노 WAV, multipart)을 재현해
   실측 SNR 까지 확인한다.
3. 에뮬레이터 마이크 켜기 — AVD 설정에서 마이크를 호스트 입력으로 연결하거나,
   오디오 파일을 마이크 입력으로 주입한다. 후자는 재현 가능한 테스트가 된다.
4. 앱에서 보호 실행 → 로그의 `[VocalCrypt] done` 과 서버 로그의
   `목표 22.0dB / 실측 21.8dB` 가 맞는지 대조한다.

### `/protect` 응답 헤더

기기에서 보호가 실제로 됐는지 앱이 따로 계산하지 않고 확인할 수 있도록
측정값을 헤더로 돌려준다.

| 헤더 | 내용 |
|---|---|
| `X-Measured-Snr` | 실측 SNR(dB). 목표값과 크게 다르면 처리가 제대로 안 된 것 |
| `X-Processing-Ms` | 서버 처리 시간 |
| `X-Sample-Rate` | 서버가 인식한 샘플레이트 |
| `X-Audio-Seconds` | 오디오 길이 |

## 배포

### 설정 (환경변수)

로컬에서는 아무것도 설정하지 않아도 지금까지와 똑같이 돈다.
배포에서는 **최소한 `VOICEGUARD_AUTH_TOKEN` 을 설정해야 한다.**

| 변수 | 기본 | 설명 |
|---|---|---|
| `VOICEGUARD_AUTH_TOKEN` | (없음) | 공유 토큰. 비어 있으면 **인증하지 않는다** |
| `VOICEGUARD_HOST` / `VOICEGUARD_PORT` | `0.0.0.0` / `8080` | bind |
| `VOICEGUARD_ALLOWED_ORIGINS` | (없음) | 쉼표 구분 CORS 출처 |
| `VOICEGUARD_MAX_UPLOAD_MB` | 32 | 업로드 상한 |
| `VOICEGUARD_MAX_FRAME_MB` | 4 | 오디오 프레임 상한 |
| `VOICEGUARD_THREADS` | CPU 수(최대 8) | 무거운 연산용 스레드 수 |
| `VOICEGUARD_LOG_LEVEL` | `INFO` | 로그 수준 |

인증 방법: HTTP 는 `Authorization: Bearer <token>`, WebSocket 은
`?token=<token>` 또는 같은 헤더. `/health` 만 토큰 없이 응답한다(상태 점검용).

### ⚠ 워커는 반드시 1개

**세션 상태가 프로세스 메모리에 있다.** 워커를 늘리면 1번 워커에서 만든
세션을 2번 워커가 모르고, `/detect` 가 404 를 낸다. `main.py` 는 `workers=1`
로 고정되어 있으니 `uvicorn --workers N` 이나 gunicorn 다중 워커로 띄우지 말 것.

수평 확장이 필요해지면 세션을 외부 저장소(Redis 등)로 빼야 한다. 그 전까지는
단일 프로세스 + 스레드풀로 처리한다.

### TLS

앱은 `wss://` 로 붙어야 한다. 서버가 직접 TLS 를 하지 않고 앞단에서 종단한다.

```nginx
location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;      # WebSocket 필수
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_read_timeout 3600s;                    # 통화 중 끊기지 않게
}
```

`proxy_read_timeout` 을 늘리지 않으면 통화 중 시그널링이 끊긴다.

### 실행

```bash
export VOICEGUARD_AUTH_TOKEN="$(openssl rand -hex 32)"
python3 main.py
```

### Flutter 쪽 대응

| 파일 | 지금 | 배포 |
|---|---|---|
| `screens/call_main_screen.dart` | `ws://10.0.2.2:8080` | `wss://<host>?token=<T>` |
| `vocalcrypt_service.dart` | `http://10.0.2.2:8765` | `https://<host>` + Bearer |
| `call_screen.dart` | `http://10.0.2.2:8765` | 같음 |

### 아직 없는 것

공유 토큰은 "앱을 쓰는 클라이언트인가"만 증명한다. **누가** 쓰는지는 증명하지
않으므로 계정 단위 대응(신고·차단·신규 계정 제한)에는 부족하다. 사용자 인증,
요청 속도 제한, 세션 외부 저장소는 별도 작업이다.

## 검증

```bash
bash tests/run_all.sh        # 전체

python3 tests/test_signaling.py   # 19 항목 — 프로토콜·세션 격리·종료
python3 tests/test_audio.py       # 14 항목 — 패킷 채널·SNR·RTF·/protect 계약
python3 tests/test_relay.py       # 20 항목 — 가상 폰 2대 양방향 중계·라우팅·지연·재접속
python3 tests/test_detect.py      # 19 항목 — 상태 기계·특징 방향성·/detect 계약
python3 tests/test_integration.py # 17 항목 — 통화 한 건 전 구간
python3 tests/test_auth.py        # 10 항목 — 토큰 인증 (서버를 토큰 모드로 띄움)
```

## 남은 정리

- (해결) 서버가 `vocalCrypt/vocalcrypt_v3.py` 원본을 직접 불러오도록 바꾸고
  `server/protect/vocalcrypt_v3.py` 복사본은 지웠다. 지우기 전에 원본과 출력이
  비트 단위로 같은 것(3초·100ms·클리핑·48kHz)과, 통화 경로로 받은 30프레임이
  원본을 직접 적용한 결과와 바이트까지 같은 것을 확인했다.
- `server.js` 는 비교용으로 남겨뒀다.
- Flutter `lib/vocalcrypt_service.dart` 와 `lib/call_screen.dart` 의
  `http://10.0.2.2:8765` 를 `:8080` 으로 바꿔야 `/protect` 가 이 서버로 붙는다.

## 다음 단계

- `detect.py` — `/detect` 엔드포인트. 세션 단위 누적 판정.
