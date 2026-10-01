"""통합 검증 — 통화 한 건의 전 구간을 끝까지 돌린다.

실행:  python3 tests/test_integration.py      (server/ 에서)

모의하는 흐름
  A(발신) ─ 시그널링 ─→ 서버 ←─ 시그널링 ─ B(수신)
     │  call_request / call_accept 로 세션 성립, 양쪽이 session_id 수신
     │
     └─ 마이크 PCM ──→ WS /audio(caller) ──VocalCrypt──→ WS /audio(callee) ──→ B 가 수신
                                                                              │
                        1초 청크 ──→ POST /detect (role=caller)   (결정 2)
                                            │
                                   세션 누적 → 상태 전이

role 규약: 수신측이 올리는 것은 **상대방** 음성이다. B(callee)가 A 의 음성을
올릴 때 role="caller" 로 보낸다. 이걸 지키지 않으면 양방향 누적이 섞인다.
"""
from __future__ import annotations

import asyncio
import io
import json
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import websockets

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import wavio  # noqa: E402

PORT = 8096
WS = f"ws://127.0.0.1:{PORT}"
HTTP = f"http://127.0.0.1:{PORT}"
SERVER_DIR = Path(__file__).resolve().parent.parent
SR = 16000
CHUNK_S = 1.0

results: list[tuple[bool, str]] = []


def check(ok: bool, label: str) -> None:
    results.append((ok, label))
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def voice(sec: float, seed: int = 0) -> np.ndarray:
    """마이크 입력 대용."""
    rng = np.random.default_rng(seed)
    n = int(sec * SR)
    t = np.arange(n) / SR
    f0 = 150 + 14 * np.sin(2 * np.pi * 0.8 * t) + rng.normal(0, 2.4, n)
    ph = 2 * np.pi * np.cumsum(f0) / SR
    x = sum(np.sin(k * ph + rng.uniform(0, 6.28)) / k ** 1.1 for k in range(1, 24))
    x *= 0.6 + 0.4 * np.sin(2 * np.pi * 2.1 * t)
    x += rng.normal(0, 0.03, n)
    return x / (np.max(np.abs(x)) + 1e-12) * 0.5


def pcm(a: np.ndarray) -> bytes:
    return (np.clip(a, -1, 1) * 32767).astype("<i2").tobytes()


def unpcm(b: bytes) -> np.ndarray:
    return np.frombuffer(b, dtype="<i2").astype(np.float64) / 32768.0


def wav(a: np.ndarray) -> bytes:
    return wavio.to_bytes(SR, a)


def snr(ref: np.ndarray, y: np.ndarray) -> float:
    n = min(len(ref), len(y))
    d = y[:n] - ref[:n]
    return 10 * np.log10(np.mean(ref[:n] ** 2) / (np.mean(d ** 2) + 1e-20))


async def recv_type(ws, want: str, timeout: float = 2.0) -> dict | None:
    end = time.time() + timeout
    while time.time() < end:
        try:
            m = json.loads(await asyncio.wait_for(ws.recv(), end - time.time()))
        except Exception:
            return None
        if m.get("type") == want:
            return m
    return None


async def run() -> None:
    import httpx

    print("\n[1] 통화 수립")
    a = await websockets.connect(WS)
    b = await websockets.connect(WS)
    await asyncio.sleep(0.2)
    await a.send(json.dumps({"type": "call_request"}))
    got = await recv_type(b, "call_request")
    check(got is not None, "B 가 call_request 수신")
    await b.send(json.dumps({"type": "call_accept"}))

    sa = await recv_type(a, "session_start")
    sb = await recv_type(b, "session_start")
    check(sa is not None and sb is not None, "양쪽 session_start 수신")
    sid = sa["session_id"]
    check(sa["session_id"] == sb["session_id"], f"session_id 일치 ({sid})")
    check(sa["role"] == "caller" and sb["role"] == "callee", "역할 부여")

    print("\n[2] A 의 음성이 보호되어 B 에게 중계 (/audio)")
    mic = voice(6.0, seed=1)
    hello = {"session_id": sid, "sample_rate": SR, "target_snr": 22.0}
    async with websockets.connect(f"{WS}/audio", max_size=16 * 1024 * 1024) as ch_a, \
            websockets.connect(f"{WS}/audio", max_size=16 * 1024 * 1024) as ch_b:
        await ch_a.send(json.dumps({**hello, "role": "caller"}))
        await ch_b.send(json.dumps({**hello, "role": "callee"}))
        ready_a = json.loads(await ch_a.recv())
        ready_b = json.loads(await ch_b.recv())
        check(ready_a.get("type") == "audio_ready" and ready_b.get("type") == "audio_ready",
              "오디오 채널 핸드셰이크 (양쪽)")

        heard = []
        step = int(CHUNK_S * SR)
        t0 = time.perf_counter()
        for i in range(0, len(mic), step):
            await ch_a.send(pcm(mic[i:i + step]))
            heard.append(unpcm(await asyncio.wait_for(ch_b.recv(), 20.0)))
        elapsed = time.perf_counter() - t0
    received = np.concatenate(heard)              # B 가 들은 것 = A 음성의 보호본
    check(len(received) == len(mic), "샘플 수 보존")
    m = snr(mic, received)
    check(abs(m - 22.0) < 2.5, f"B 가 들은 음성의 보호 SNR {m:.1f}dB (목표 22dB)")
    rtf = elapsed / (len(mic) / SR)
    check(rtf < 1.0, f"중계 경로 RTF {rtf:.3f} (실시간 여유)")

    print("\n[3] B 가 수신 오디오를 청크로 올림 (/detect, role=caller)")
    states, scores = [], []
    async with httpx.AsyncClient(base_url=HTTP, timeout=60.0) as cli:
        step = int(CHUNK_S * SR)
        for i in range(0, len(received) - step + 1, step):
            r = await cli.post(
                "/detect",
                files={"file": ("c.wav", wav(received[i:i + step]), "audio/wav")},
                data={"session_id": sid, "role": "caller"})
            if r.status_code != 200:
                break
            j = r.json()
            states.append(j["state"])
            scores.append(j["p_spoof"])
        check(r.status_code == 200, f"청크 업로드 200 ({r.status_code})")
        check(len(states) == 6, f"6개 청크 누적 ({len(states)})")
        check(states[0] == "analyzing", "첫 청크는 analyzing")
        check(all(s in ("analyzing", "human", "ai_suspected", "ai_detected")
                  for s in states), "상태값이 정의된 집합 안")
        check(j["chunks"] == 6, f"서버 누적 개수 일치 ({j['chunks']})")
        print(f"      점수 {[round(x, 3) for x in scores]}")
        print(f"      상태 {states}")
        print(f"      calibrated={j['calibrated']}  <- False 이면 절대값 무의미")

        print("\n[4] 반대 방향은 독립 누적")
        r = await cli.post("/detect",
                           files={"file": ("c.wav", wav(voice(1.0, 9)), "audio/wav")},
                           data={"session_id": sid, "role": "callee"})
        check(r.json()["chunks"] == 1, "role 별 누적 분리")

        print("\n[5] 통화 종료 후 정리")
        await a.send(json.dumps({"type": "hang_up"}))
        end_b = await recv_type(b, "session_end")
        check(end_b is not None, "B 가 session_end 수신")

        r = await cli.post("/detect",
                           files={"file": ("c.wav", wav(voice(1.0)), "audio/wav")},
                           data={"session_id": sid, "role": "caller"})
        check(r.status_code == 404, f"종료된 세션은 404 ({r.status_code})")

        try:
            async with websockets.connect(f"{WS}/audio") as ch:
                await ch.send(json.dumps({"session_id": sid, "sample_rate": SR}))
                await asyncio.wait_for(ch.recv(), 1.0)
            check(False, "종료된 세션의 오디오 채널 거절")
        except Exception:
            check(True, "종료된 세션의 오디오 채널 거절")

    await a.close()
    await b.close()


async def main() -> int:
    proc = subprocess.Popen(
        [sys.executable, "-m", "uvicorn", "main:app", "--host", "127.0.0.1",
         "--port", str(PORT), "--log-level", "error"],
        cwd=SERVER_DIR, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        for _ in range(60):
            try:
                async with websockets.connect(WS) as ws:
                    await ws.close()
                break
            except Exception:
                await asyncio.sleep(0.2)
        else:
            print("서버 기동 실패:", proc.stderr.read().decode()[-600:])
            return 1
        await run()
    finally:
        proc.terminate()
        proc.wait(timeout=5)

    passed = sum(1 for ok, _ in results if ok)
    print(f"\n{'=' * 52}\n  {passed}/{len(results)} 통과")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
