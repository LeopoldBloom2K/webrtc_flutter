"""배포 설정 검증 — 토큰 인증이 실제로 막는지 확인한다.

실행:  python3 tests/test_auth.py      (server/ 에서)

로컬 기본값(토큰 없음)에서는 인증을 하지 않는다. 이 테스트는 서버를
VOICEGUARD_AUTH_TOKEN 을 준 상태로 띄워서 그 경로를 확인한다.
"""
from __future__ import annotations

import asyncio
import io
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import websockets

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import wavio  # noqa: E402

PORT = 8095
WS = f"ws://127.0.0.1:{PORT}"
HTTP = f"http://127.0.0.1:{PORT}"
SERVER_DIR = Path(__file__).resolve().parent.parent
TOKEN = "test-token-do-not-ship"
SR = 16000

results: list[tuple[bool, str]] = []


def check(ok: bool, label: str) -> None:
    results.append((ok, label))
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def wav_bytes() -> bytes:
    t = np.arange(SR) / SR
    x = np.sin(2 * np.pi * 150 * t) * 0.4
    return wavio.to_bytes(SR, x)


async def ws_ok(url: str, **kw) -> bool:
    try:
        async with websockets.connect(url, **kw) as ws:
            await ws.send(json.dumps({"type": "call_request"}))
            await asyncio.sleep(0.25)
            return ws.state.name == "OPEN"
    except Exception:
        return False


async def run() -> None:
    import httpx

    print("\n[1] WebSocket 시그널링")
    check(not await ws_ok(WS), "토큰 없이 접속 거절")
    check(not await ws_ok(f"{WS}?token=wrong"), "잘못된 토큰 거절")
    check(await ws_ok(f"{WS}?token={TOKEN}"), "쿼리 파라미터 토큰 허용")
    check(await ws_ok(WS, additional_headers={"Authorization": f"Bearer {TOKEN}"}),
          "Authorization 헤더 토큰 허용")

    print("\n[2] HTTP 엔드포인트")
    async with httpx.AsyncClient(base_url=HTTP, timeout=30.0) as cli:
        r = await cli.post("/protect",
                           files={"file": ("a.wav", wav_bytes(), "audio/wav")},
                           data={"target_snr": "22.0"})
        check(r.status_code == 401, f"/protect 토큰 없이 401 ({r.status_code})")

        r = await cli.post("/protect",
                           files={"file": ("a.wav", wav_bytes(), "audio/wav")},
                           data={"target_snr": "22.0"},
                           headers={"Authorization": f"Bearer {TOKEN}"})
        check(r.status_code == 200, f"/protect 토큰으로 200 ({r.status_code})")

        r = await cli.post("/detect",
                           files={"file": ("a.wav", wav_bytes(), "audio/wav")},
                           data={"session_id": "x", "role": "caller"})
        check(r.status_code == 401, f"/detect 토큰 없이 401 ({r.status_code})")

        r = await cli.post("/detect",
                           files={"file": ("a.wav", wav_bytes(), "audio/wav")},
                           data={"session_id": "x", "role": "caller"},
                           headers={"Authorization": f"Bearer {TOKEN}"})
        check(r.status_code == 404,
              f"/detect 토큰 통과 후 세션 검사까지 진행 ({r.status_code})")

        r = await cli.get("/health")
        check(r.status_code == 200, "/health 는 토큰 없이도 응답 (상태 점검용)")

    print("\n[3] 오디오 채널")
    try:
        async with websockets.connect(f"{WS}/audio") as ch:
            await ch.send(json.dumps({"session_id": "x", "sample_rate": SR}))
            await asyncio.wait_for(ch.recv(), 1.0)
        check(False, "/audio 토큰 없이 거절")
    except Exception:
        check(True, "/audio 토큰 없이 거절")


async def main() -> int:
    env = dict(os.environ, VOICEGUARD_AUTH_TOKEN=TOKEN, VOICEGUARD_LOG_LEVEL="ERROR")
    proc = subprocess.Popen(
        [sys.executable, "-m", "uvicorn", "main:app", "--host", "127.0.0.1",
         "--port", str(PORT), "--log-level", "error"],
        cwd=SERVER_DIR, env=env,
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        import httpx
        for _ in range(60):
            try:
                async with httpx.AsyncClient(timeout=2.0) as c:
                    if (await c.get(f"{HTTP}/health")).status_code == 200:
                        break
            except Exception:
                pass
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
