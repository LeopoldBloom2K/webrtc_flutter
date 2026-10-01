"""탐지 경로 검증 — 상태 기계와 /detect 계약.

실행:  python3 tests/test_detect.py      (server/ 에서)

주의: 이 테스트는 **파이프라인이 도는지**를 본다. 탐지 성능을 재는 것이
아니다. 임계값이 아직 보정되지 않았으므로 절대 점수는 의미가 없다.
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

PORT = 8097
WS = f"ws://127.0.0.1:{PORT}"
HTTP = f"http://127.0.0.1:{PORT}"
SERVER_DIR = Path(__file__).resolve().parent.parent
SR = 16000

results: list[tuple[bool, str]] = []


def check(ok: bool, label: str) -> None:
    results.append((ok, label))
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def natural(sec: float = 1.0, seed: int = 0) -> np.ndarray:
    """자연 발화 근사 — F0 지터, 진폭 변동, 기식 잡음."""
    rng = np.random.default_rng(seed)
    n = int(sec * SR)
    t = np.arange(n) / SR
    f0 = 140 + 12 * np.sin(2 * np.pi * 1.7 * t) + rng.normal(0, 2.2, n)
    ph = 2 * np.pi * np.cumsum(f0) / SR
    x = sum(np.sin(k * ph + rng.uniform(0, 6.28)) / k for k in range(1, 22))
    x *= 0.65 + 0.35 * np.sin(2 * np.pi * 2.3 * t) + rng.normal(0, 0.05, n)
    x += rng.normal(0, 0.035, n)                       # 기식 성분
    return x / (np.max(np.abs(x)) + 1e-12) * 0.5


def over_regular(sec: float = 1.0) -> np.ndarray:
    """과도하게 규칙적인 신호 — 지터/잡음 없음, 고역 차단."""
    n = int(sec * SR)
    t = np.arange(n) / SR
    ph = 2 * np.pi * 140.0 * t
    x = sum(np.sin(k * ph) / k for k in range(1, 12))   # 고역 성분 자체가 없음
    return x / (np.max(np.abs(x)) + 1e-12) * 0.5


def wav(a: np.ndarray) -> bytes:
    import wavio
    return wavio.to_bytes(SR, a)


def test_track_unit() -> None:
    """상태 기계는 서버 없이 바로 검증한다."""
    from session import AI_DETECTED, AI_SUSPECTED, ANALYZING, HUMAN, Track

    print("\n[1] Track 상태 기계 (단위)")
    t = Track(window=5, suspect_at=0.60, detect_at=0.80, hold_chunks=3)
    states = [t.push(0.1) for _ in range(4)]
    check(all(s == ANALYZING for s in states), "창이 차기 전엔 analyzing")
    check(t.push(0.1) == HUMAN, "낮은 점수가 쌓이면 human")

    t2 = Track(window=5, suspect_at=0.60, detect_at=0.80, hold_chunks=3)
    for _ in range(5):
        t2.push(0.70)
    check(t2.state == AI_SUSPECTED, "중간 점수는 ai_suspected 에서 멈춤")
    check(t2.push(0.70) == AI_SUSPECTED, "확정으로 넘어가지 않음")

    t3 = Track(window=5, suspect_at=0.60, detect_at=0.80, hold_chunks=3)
    seq = [t3.push(0.95) for _ in range(8)]
    check(AI_DETECTED in seq, "높은 점수가 유지되면 ai_detected")
    # 창(5)이 찬 뒤 hold_chunks(3) 만큼 연속 초과 -> 5 + 3 - 1 = 7번째 청크
    idx = seq.index(AI_DETECTED)
    check(idx + 1 == 5 + 3 - 1, f"확정까지 창+유지 만큼 걸림 (청크 {idx + 1}개)")
    for _ in range(10):
        t3.push(0.05)
    check(t3.state == AI_DETECTED, "확정은 되돌리지 않음")


def test_scorer_direction() -> None:
    """특징이 기대한 방향으로 움직이는지만 본다 (성능 측정 아님)."""
    from detect import DEFAULT

    print("\n[2] 특징 방향성 (보정 전 참고용)")
    pn, fn = DEFAULT.score(natural(1.0), SR)
    po, fo = DEFAULT.score(over_regular(1.0), SR)
    print(f"      자연 근사    p={pn:.3f}  jitter={fn['jitter']:.4f} "
          f"hnr={fn['hnr_db']:.1f}dB hf={fn['hf_ratio']:.4f}")
    print(f"      과규칙 신호  p={po:.3f}  jitter={fo['jitter']:.4f} "
          f"hnr={fo['hnr_db']:.1f}dB hf={fo['hf_ratio']:.4f}")
    check(po > pn, "과규칙 신호가 더 높은 p_spoof")
    check(0.0 <= pn <= 1.0 and 0.0 <= po <= 1.0, "점수가 [0,1] 범위")

    ps, fs = DEFAULT.score(np.zeros(SR), SR)
    check(ps == 0.5 and fs["_skipped"] == 1.0, "무음 청크는 판단 보류(0.5)")


async def pair_session():
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


async def test_api() -> None:
    import httpx

    print("\n[3] /detect 계약")
    sid, a, b = await pair_session()
    async with httpx.AsyncClient(base_url=HTTP, timeout=60.0) as cli:
        r = await cli.post("/detect",
                           files={"file": ("c.wav", wav(natural()), "audio/wav")},
                           data={"session_id": "nope", "role": "callee"})
        check(r.status_code == 404, f"알 수 없는 session_id 는 404 ({r.status_code})")

        r = await cli.post("/detect",
                           files={"file": ("c.wav", wav(natural()), "audio/wav")},
                           data={"session_id": sid, "role": "bogus"})
        check(r.status_code == 400, f"잘못된 role 은 400 ({r.status_code})")

        states = []
        for i in range(7):
            r = await cli.post(
                "/detect",
                files={"file": ("c.wav", wav(natural(1.0, seed=i)), "audio/wav")},
                data={"session_id": sid, "role": "callee"})
            if r.status_code != 200:
                break
            j = r.json()
            states.append(j["state"])
        check(r.status_code == 200, f"정상 요청 200 ({r.status_code})")
        check(j["calibrated"] is False, "calibrated=false 로 미보정 표시")
        check(j["chunks"] == 7, f"세션에 누적됨 (chunks={j.get('chunks')})")
        check(states[0] == "analyzing", "첫 청크는 analyzing")
        check(all(k in j["features"] for k in ("jitter", "hnr_db", "hf_ratio")),
              "특징이 응답에 포함됨")
        check(j["latency_ms"] < 500, f"청크 채점 {j['latency_ms']:.0f}ms")

        # 반대 방향(role)은 독립 누적
        r = await cli.post("/detect",
                           files={"file": ("c.wav", wav(natural()), "audio/wav")},
                           data={"session_id": sid, "role": "caller"})
        check(r.json()["chunks"] == 1, "role 별로 누적이 분리됨")

    await a.close()
    await b.close()


async def main() -> int:
    test_track_unit()
    test_scorer_direction()

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
        await test_api()
    finally:
        proc.terminate()
        proc.wait(timeout=5)

    passed = sum(1 for ok, _ in results if ok)
    print(f"\n{'=' * 52}\n  {passed}/{len(results)} 통과")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
