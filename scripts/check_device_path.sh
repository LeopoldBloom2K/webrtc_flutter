#!/usr/bin/env bash
# 기기/에뮬레이터 경로 점검 — 앱이 하는 것과 같은 요청을 밖에서 재현한다.
#
#   bash scripts/check_device_path.sh                      # 기본 127.0.0.1:8080
#   bash scripts/check_device_path.sh http://10.0.2.2:8080 # 에뮬레이터 안에서
#
# 앱이 보내는 것과 동일: 3초 모노 WAV, multipart, target_snr=22
# VOICEGUARD_AUTH_TOKEN 이 설정돼 있으면 Bearer 토큰을 함께 보낸다.
set -eu

HOST="${1:-http://127.0.0.1:8080}"
TOKEN="${VOICEGUARD_AUTH_TOKEN:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SERVER_DIR="$HERE/../server"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# macOS 기본 bash 3.2 는 set -u 에서 빈 배열 전개를 거부한다. 함수로 감싼다.
req() {
  if [ -n "$TOKEN" ]; then
    curl -sS -H "Authorization: Bearer $TOKEN" "$@"
  else
    curl -sS "$@"
  fi
}

echo "대상: $HOST"
[ -n "$TOKEN" ] && echo "인증: Bearer 토큰 사용" || echo "인증: 없음"

echo "--- /health"
if ! req --max-time 5 "$HOST/health"; then
  echo
  echo "  연결 실패. 서버가 떠 있는지 확인하세요:  cd server && python main.py"
  exit 1
fi
echo

echo "--- 3초 테스트 음성 생성 (16kHz 모노)"
SERVER_DIR="$SERVER_DIR" python3 - "$TMP/in.wav" <<'PY'
import os, sys
sys.path.insert(0, os.environ["SERVER_DIR"])
import numpy as np
import wavio
sr = 16000
t = np.arange(int(3 * sr)) / sr
rng = np.random.default_rng(0)
f0 = 150 + 14 * np.sin(2 * np.pi * 0.8 * t) + rng.normal(0, 2.4, len(t))
ph = 2 * np.pi * np.cumsum(f0) / sr
x = sum(np.sin(k * ph + rng.uniform(0, 6.28)) / k ** 1.1 for k in range(1, 24))
x += rng.normal(0, 0.03, len(t))
x = x / (np.max(np.abs(x)) + 1e-12) * 0.5
wavio.write(sys.argv[1], sr, x)
print(f"  {len(x)} 샘플, {len(x)/sr:.1f}초")
PY

echo "--- POST /protect"
set +e
req -D "$TMP/h.txt" -o "$TMP/out.wav" --max-time 60 \
  -F "file=@$TMP/in.wav;type=audio/wav" -F "target_snr=22.0" \
  "$HOST/protect"
rc=$?
set -e
if [ $rc -ne 0 ]; then echo "  요청 실패 (curl $rc)"; exit 1; fi

code="$(head -1 "$TMP/h.txt" | awk '{print $2}')"
echo "  HTTP $code"
if [ "$code" != "200" ]; then
  echo "  본문:"; head -c 400 "$TMP/out.wav"; echo; exit 1
fi
grep -iE "^x-(measured-snr|processing-ms|sample-rate|audio-seconds)" "$TMP/h.txt" \
  | tr -d '\r' | sed 's/^/  /'

echo "--- 결과 확인"
SERVER_DIR="$SERVER_DIR" python3 - "$TMP/in.wav" "$TMP/out.wav" <<'PY'
import os, sys
sys.path.insert(0, os.environ["SERVER_DIR"])
import numpy as np
import wavio
_, a = wavio.read(sys.argv[1])
_, b = wavio.read(sys.argv[2])
n = min(len(a), len(b))
d = b[:n] - a[:n]
snr = 10 * np.log10(np.mean(a[:n] ** 2) / (np.mean(d ** 2) + 1e-20))
print(f"  샘플 수 {len(a)} -> {len(b)}")
print(f"  실측 SNR {snr:.1f} dB")
print("  노이즈 주입 확인" if np.mean(d ** 2) > 1e-9
      else "  !! 노이즈가 없습니다 (무음 입력이거나 처리 실패)")
PY
echo
echo "서버 경로 정상. 다음: 에뮬레이터 마이크 켜고 앱에서 보호 버튼."
