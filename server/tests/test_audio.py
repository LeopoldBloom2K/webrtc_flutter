"""오디오 경로 검증 — /audio 패킷 채널과 /protect 엔드포인트.

실행:  python3 tests/test_audio.py      (server/ 에서)

검사 항목
  1. 세션 없는 /audio 접속은 거절된다
  2. 세션에 묶인 /audio 로 PCM 을 보내면 VocalCrypt 가 적용되어 상대방 채널로 간다
  3. 실측 SNR 이 목표 SNR 과 맞는다
  4. 청크 길이별 RTF (중계 경로 기준, 실시간 가능 여부)
  5. /protect HTTP 계약이 기존과 동일하게 동작한다
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

PORT = 8098
WS = f"ws://127.0.0.1:{PORT}"
HTTP = f"http://127.0.0.1:{PORT}"
SERVER_DIR = Path(__file__).resolve().parent.parent
SR = 16000

results: list[tuple[bool, str]] = []


def check(ok: bool, label: str) -> None:
    results.append((ok, label))
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def speech(seconds: float, f0: float = 140.0) -> np.ndarray:
    """포먼트를 가진 유성음 근사."""
    n = int(seconds * SR)
    t = np.arange(n) / SR
    x = np.zeros(n)
    for k in range(1, 20):
        if k * f0 >= SR / 2 * 0.9:
            break
        x += np.sin(2 * np.pi * k * f0 * t + k) / k
    env = 0.6 + 0.4 * np.sin(2 * np.pi * 3.0 * t)
    x *= env
    return x / (np.max(np.abs(x)) + 1e-12) * 0.5


def to_pcm(a: np.ndarray) -> bytes:
    return (np.clip(a, -1, 1) * 32767).astype("<i2").tobytes()


def from_pcm(b: bytes) -> np.ndarray:
    return np.frombuffer(b, dtype="<i2").astype(np.float64) / 32768.0


def snr(ref: np.ndarray, y: np.ndarray) -> float:
    n = min(len(ref), len(y))
    d = y[:n] - ref[:n]
    return 10 * np.log10(np.mean(ref[:n] ** 2) / (np.mean(d ** 2) + 1e-20))


async def pair_session() -> tuple[str, object, object]:
    a = await websockets.connect(WS)
    b = await websockets.connect(WS)
    await asyncio.sleep(0.2)
    await a.send(json.dumps({"type": "call_request"}))
    await asyncio.sleep(0.2)
    await b.recv()
    await b.send(json.dumps({"type": "call_accept"}))
    sid = None
    for _ in range(3):
        try:
            m = json.loads(await asyncio.wait_for(a.recv(), 0.5))
            if m.get("type") == "session_start":
                sid = m["session_id"]
                break
        except asyncio.TimeoutError:
            break
    return sid, a, b


async def scenario() -> None:
    import httpx

    print("\n[1] 세션 없는 /audio 접속")
    try:
        async with websockets.connect(f"{WS}/audio") as ws:
            await ws.send(json.dumps({"session_id": "deadbeef", "sample_rate": SR}))
            await asyncio.wait_for(ws.recv(), 1.0)
        check(False, "세션 없는 접속이 거절됨")
    except Exception:
        check(True, "세션 없는 접속이 거절됨")

    sid, sig_a, sig_b = await pair_session()
    check(sid is not None, f"시그널링에서 session_id 확보 ({sid})")

    print("\n[2] 오디오 패킷 중계 (caller → callee)")
    hello = {"session_id": sid, "sample_rate": SR, "target_snr": 22.0}
    async with websockets.connect(f"{WS}/audio", max_size=8 * 1024 * 1024) as ws, \
            websockets.connect(f"{WS}/audio", max_size=8 * 1024 * 1024) as peer:
        await ws.send(json.dumps({**hello, "role": "caller"}))
        ready = json.loads(await ws.recv())
        check(ready.get("type") == "audio_ready", "핸드셰이크 응답 수신")
        await peer.send(json.dumps({**hello, "role": "callee"}))
        await peer.recv()                                   # audio_ready

        src = speech(1.0)
        await ws.send(to_pcm(src))
        out = from_pcm(await asyncio.wait_for(peer.recv(), 10.0))
        check(len(out) == len(src), f"샘플 수 보존 ({len(out)})")
        check(not np.allclose(out, src, atol=1e-3), "노이즈가 실제로 주입됨")
        measured = snr(src, out)
        check(abs(measured - 22.0) < 2.0, f"실측 SNR {measured:.1f}dB (목표 22dB)")

        print("\n[3] 청크 길이별 RTF (중계 경로)")
        print(f"      {'청크':>8}{'처리':>10}{'RTF':>9}   판정")
        for ms in (20, 100, 500, 1000, 2000):
            chunk = speech(ms / 1000.0)
            t0 = time.perf_counter()
            await ws.send(to_pcm(chunk))
            await asyncio.wait_for(peer.recv(), 30.0)
            el = (time.perf_counter() - t0) * 1000.0
            rtf = el / ms
            verdict = "실시간 불가" if rtf >= 1.0 else "여유"
            print(f"      {ms:6d}ms{el:9.1f}ms{rtf:9.3f}   {verdict}")

    await sig_a.close()
    await sig_b.close()

    print("\n[4] /protect HTTP 계약")
    src = speech(2.0)
    buf = io.BytesIO(wavio.to_bytes(SR, src))
    async with httpx.AsyncClient(base_url=HTTP, timeout=60.0) as cli:
        r = await cli.post("/protect",
                           files={"file": ("audio.wav", buf.getvalue(), "audio/wav")},
                           data={"target_snr": "22.0"})
        check(r.status_code == 200, f"200 응답 ({r.status_code})")
        check(r.headers.get("content-type") == "audio/wav", "audio/wav 반환")
        sr2, got = wavio.read(r.content)
        check(sr2 == SR, f"샘플레이트 보존 ({sr2})")
        check(np.max(np.abs(got)) <= 1.0, "정규화 범위 내 PCM 반환")
        m = snr(src, got)
        check(abs(m - 22.0) < 2.0, f"실측 SNR {m:.1f}dB")

        r = await cli.post("/protect",
                           files={"file": ("x.wav", b"not a wav", "audio/wav")},
                           data={"target_snr": "22.0"})
        check(r.status_code == 400, f"잘못된 WAV 는 400 ({r.status_code})")

        r = await cli.post("/protect",
                           files={"file": ("audio.wav", buf.getvalue(), "audio/wav")},
                           data={"target_snr": "999"})
        check(r.status_code == 400, f"범위 밖 target_snr 은 400 ({r.status_code})")

        r = await cli.get("/health")
        check(r.status_code == 200 and r.json().get("status") == "ok", "/health 정상")


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
        await scenario()
    finally:
        proc.terminate()
        proc.wait(timeout=5)

    passed = sum(1 for ok, _ in results if ok)
    print(f"\n{'=' * 52}\n  {passed}/{len(results)} 통과")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
