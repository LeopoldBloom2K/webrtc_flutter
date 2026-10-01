"""서버 경유 통화 중계 검증 — 가상 폰 두 대가 실시간 속도로 서로 말한다.

실행:  python3 tests/test_relay.py      (server/ 에서)

    폰A ─100ms PCM─▶ /audio(caller) ─VocalCrypt─▶ /audio(callee) ─▶ 폰B
    폰B ─100ms PCM─▶ /audio(callee) ─VocalCrypt─▶ /audio(caller) ─▶ 폰A

두 폰이 서로 다른 음성(F0 130Hz / 210Hz)을 동시에 보낸다. 받은 쪽이 상대 음성과만
상관이 높으면 방향이 맞게 중계된 것이다. 앱과 같은 프레임 길이(100ms)와 같은
송신 속도(실시간)로 보낸다.

검사 항목
  1. 시그널링 → session_start → /audio 핸드셰이크를 실제 프로토콜로 수립
  2. 양방향 라우팅: A 는 B 의 음성만, B 는 A 의 음성만 받는다
  3. 보호: 받은 음성의 SNR 이 목표(22dB)에 맞고 원음과 다르다
  4. 연속성: 보낸 샘플 수와 받은 샘플 수가 같다(누락·중복 없음)
  5. 지연: 프레임별 송신→수신 지연, 통화가 길어져도 누적되지 않는다
  6. 상대가 끊겼을 때 송신측은 계속 동작하고, 재접속하면 중계가 재개된다
  7. 잘못된 role 은 거절, 통화 종료 후 채널은 거절
"""
from __future__ import annotations

import asyncio
import json
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import websockets

PORT = 8094
WS = f"ws://127.0.0.1:{PORT}"
SERVER_DIR = Path(__file__).resolve().parent.parent
SR = 16000
FRAME_MS = 100                       # 앱과 같은 프레임 길이
FRAME = SR * FRAME_MS // 1000
SECONDS = 6.0
TARGET = 22.0

results: list[tuple[bool, str]] = []


def check(ok: bool, label: str) -> None:
    results.append((ok, label))
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def voice(sec: float, f0: float, seed: int) -> np.ndarray:
    """억양과 진폭 변화가 있는 유성음 근사. 화자마다 F0 를 다르게 준다."""
    rng = np.random.default_rng(seed)
    n = int(sec * SR)
    t = np.arange(n) / SR
    f = f0 + 0.1 * f0 * np.sin(2 * np.pi * 0.8 * t) + rng.normal(0, 2.0, n)
    ph = 2 * np.pi * np.cumsum(f) / SR
    x = sum(np.sin(k * ph + rng.uniform(0, 6.28)) / k ** 1.1 for k in range(1, 24)
            if k * f0 < SR / 2 * 0.9)
    x *= 0.6 + 0.4 * np.sin(2 * np.pi * 2.1 * t + seed)
    x += rng.normal(0, 0.02, n)
    return x / (np.max(np.abs(x)) + 1e-12) * 0.5


def pcm(a: np.ndarray) -> bytes:
    return (np.clip(a, -1, 1) * 32767).astype("<i2").tobytes()


def unpcm(b: bytes) -> np.ndarray:
    return np.frombuffer(b, dtype="<i2").astype(np.float64) / 32768.0


def corr(a: np.ndarray, b: np.ndarray) -> float:
    n = min(len(a), len(b))
    a, b = a[:n] - a[:n].mean(), b[:n] - b[:n].mean()
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-20))


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


async def open_channel(sid: str, role: str):
    ch = await websockets.connect(f"{WS}/audio", max_size=4 * 1024 * 1024)
    await ch.send(json.dumps({"session_id": sid, "role": role,
                              "sample_rate": SR, "target_snr": TARGET}))
    ready = json.loads(await asyncio.wait_for(ch.recv(), 3.0))
    return ch, ready


class Phone:
    """앱의 AudioRelay 와 같은 동작: 100ms 마다 한 프레임을 보내고, 받는 대로 쌓는다."""

    def __init__(self, ch, src: np.ndarray) -> None:
        self.ch = ch
        self.src = src
        self.sent_at: list[float] = []
        self.got: list[np.ndarray] = []
        self.got_at: list[float] = []

    async def talk(self, t0: float) -> None:
        for i, k in enumerate(range(0, len(self.src) - FRAME + 1, FRAME)):
            await asyncio.sleep(max(0.0, t0 + i * FRAME_MS / 1000 - time.perf_counter()))
            self.sent_at.append(time.perf_counter())
            await self.ch.send(pcm(self.src[k:k + FRAME]))

    async def listen(self, expect: int, timeout: float) -> None:
        end = time.perf_counter() + timeout
        while len(self.got) < expect and time.perf_counter() < end:
            try:
                m = await asyncio.wait_for(self.ch.recv(), end - time.perf_counter())
            except asyncio.TimeoutError:
                break
            if isinstance(m, bytes):
                self.got_at.append(time.perf_counter())
                self.got.append(unpcm(m))

    @property
    def heard(self) -> np.ndarray:
        return np.concatenate(self.got) if self.got else np.zeros(0)


async def scenario() -> None:
    print("\n[1] 통화 수립 (시그널링 → session_start → /audio)")
    a = await websockets.connect(WS)
    b = await websockets.connect(WS)
    await asyncio.sleep(0.2)
    await a.send(json.dumps({"type": "call_request"}))
    check(await recv_type(b, "call_request") is not None, "B 가 call_request 수신")
    await b.send(json.dumps({"type": "call_accept"}))
    sa = await recv_type(a, "session_start")
    sb = await recv_type(b, "session_start")
    check(sa is not None and sb is not None, "양쪽 session_start 수신")
    sid = sa["session_id"]

    ch_a, ra = await open_channel(sid, sa["role"])
    ch_b, rb = await open_channel(sid, sb["role"])
    check(ra.get("type") == "audio_ready" and rb.get("type") == "audio_ready",
          f"양쪽 audio_ready ({sa['role']} / {sb['role']})")

    print(f"\n[2] 동시 통화 {SECONDS:.0f}초 — {FRAME_MS}ms 프레임, 실시간 속도")
    src_a = unpcm(pcm(voice(SECONDS, 130.0, seed=1)))     # 양자화까지 맞춘 원음
    src_b = unpcm(pcm(voice(SECONDS, 210.0, seed=2)))
    pa, pb = Phone(ch_a, src_a), Phone(ch_b, src_b)
    n_frames = len(src_a) // FRAME
    t0 = time.perf_counter() + 0.05
    await asyncio.gather(pa.talk(t0), pb.talk(t0),
                         pa.listen(n_frames, SECONDS + 5), pb.listen(n_frames, SECONDS + 5))

    heard_b, heard_a = pb.heard, pa.heard               # B 가 들은 것 = A 의 보호본
    check(len(pb.got) == n_frames and len(pa.got) == n_frames,
          f"프레임 누락 없음 (A→B {len(pb.got)}/{n_frames}, B→A {len(pa.got)}/{n_frames})")
    check(len(heard_b) == len(src_a) and len(heard_a) == len(src_b),
          f"샘플 수 보존 ({len(heard_b)} / {len(src_a)})")

    c_ab, c_ab_wrong = corr(heard_b, src_a), corr(heard_b, src_b)
    c_ba, c_ba_wrong = corr(heard_a, src_b), corr(heard_a, src_a)
    print(f"      B 가 들은 소리  vs A 원음 {c_ab:.3f}   vs B 자기 원음 {c_ab_wrong:+.3f}")
    print(f"      A 가 들은 소리  vs B 원음 {c_ba:.3f}   vs A 자기 원음 {c_ba_wrong:+.3f}")
    check(c_ab > 0.95 and abs(c_ab_wrong) < 0.1, "B 는 A 의 음성만 듣는다")
    check(c_ba > 0.95 and abs(c_ba_wrong) < 0.1, "A 는 B 의 음성만 듣는다")

    print("\n[3] 상대가 듣는 것은 보호된 음성")
    s_ab, s_ba = snr(src_a, heard_b), snr(src_b, heard_a)
    check(abs(s_ab - TARGET) < 2.5, f"A→B SNR {s_ab:.1f}dB (목표 {TARGET:.0f}dB)")
    check(abs(s_ba - TARGET) < 2.5, f"B→A SNR {s_ba:.1f}dB (목표 {TARGET:.0f}dB)")
    check(not np.allclose(heard_b, src_a, atol=1e-3), "원음이 그대로 전달되지 않음")

    noise = heard_b - src_a
    d = np.abs(np.diff(noise))
    bidx = np.arange(FRAME, len(noise), FRAME) - 1
    mask = np.ones(len(d), bool)
    mask[bidx] = False
    print(f"      청크 경계 점프: 내부의 {np.median(d[bidx]) / np.median(d[mask]):.1f}배 "
          f"(참고 — A파트 알고리즘의 청크 독립 처리에서 생김)")

    print("\n[4] 지연 (송신 직전 → 상대 수신, 같은 시계)")
    for name, tx, rx in (("A→B", pa, pb), ("B→A", pb, pa)):
        lat = (np.array(rx.got_at) - np.array(tx.sent_at[:len(rx.got_at)])) * 1000
        first, last = np.median(lat[:10]), np.median(lat[-10:])
        print(f"      {name}  중앙값 {np.median(lat):5.1f}ms  p95 {np.percentile(lat, 95):5.1f}ms  "
              f"처음 10프레임 {first:5.1f}ms → 마지막 10프레임 {last:5.1f}ms")
        check(np.percentile(lat, 95) < 150.0, f"{name} 서버 구간 지연 p95 < 150ms")
        check(last - first < 50.0, f"{name} 지연이 누적되지 않음 (실시간 처리 가능)")

    print("\n[5] 상대가 끊겼다가 다시 들어올 때")
    await ch_b.close()
    await asyncio.sleep(0.2)
    for k in range(5):                                   # 받을 사람이 없는 동안 송신
        await ch_a.send(pcm(src_a[k * FRAME:(k + 1) * FRAME]))
    await asyncio.sleep(0.5)
    ch_b2, rb2 = await open_channel(sid, "callee")
    check(rb2.get("type") == "audio_ready", "B 재접속 핸드셰이크")
    await ch_a.send(pcm(src_a[:FRAME]))
    try:
        m = await asyncio.wait_for(ch_b2.recv(), 3.0)
        check(isinstance(m, bytes) and len(m) == FRAME * 2, "재접속 후 중계 재개")
    except asyncio.TimeoutError:
        check(False, "재접속 후 중계 재개")
    try:                                                 # 끊긴 동안 보낸 5프레임이 밀려오면 안 된다
        extra = await asyncio.wait_for(ch_b2.recv(), 0.5)
        check(False, f"끊긴 동안의 프레임은 버려짐 (추가 수신 {len(extra)}B)")
    except asyncio.TimeoutError:
        check(True, "끊긴 동안의 프레임은 버려짐")

    print("\n[6] 거절되어야 하는 접속")
    try:
        bad = await websockets.connect(f"{WS}/audio")
        await bad.send(json.dumps({"session_id": sid, "role": "spy", "sample_rate": SR}))
        await asyncio.wait_for(bad.recv(), 1.0)
        check(False, "잘못된 role 거절")
    except Exception:
        check(True, "잘못된 role 거절")

    await a.send(json.dumps({"type": "hang_up"}))
    check(await recv_type(b, "session_end") is not None, "통화 종료 시 session_end")
    try:
        late = await websockets.connect(f"{WS}/audio")
        await late.send(json.dumps({"session_id": sid, "role": "caller", "sample_rate": SR}))
        await asyncio.wait_for(late.recv(), 1.0)
        check(False, "종료된 세션의 채널 거절")
    except Exception:
        check(True, "종료된 세션의 채널 거절")

    for ws in (ch_a, ch_b2, a, b):
        await ws.close()


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
