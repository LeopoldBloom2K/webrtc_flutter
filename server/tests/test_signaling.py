"""시그널링 서버 검증 — 프로토콜 호환성과 세션 격리를 확인한다.

실행:  python3 tests/test_signaling.py      (server/ 에서)

검사 항목
  1. 기존 8종 메시지가 그대로 오간다
  2. 통화가 성립하면 제3자에게 SDP/ICE 가 새지 않는다   <- 기존 Node 서버의 결함
  3. session_start / session_end 가 양쪽에 전달된다
  4. 한쪽 연결이 끊기면 상대가 통보받는다
"""
from __future__ import annotations

import asyncio
import json
import subprocess
import sys
import time
from pathlib import Path

import websockets

PORT = 8099
URL = f"ws://127.0.0.1:{PORT}"
SERVER_DIR = Path(__file__).resolve().parent.parent

results: list[tuple[bool, str]] = []


def check(ok: bool, label: str) -> None:
    results.append((ok, label))
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


async def drain(ws, timeout: float = 0.4) -> list[dict]:
    """대기 중인 메시지를 모두 수거한다."""
    out = []
    while True:
        try:
            raw = await asyncio.wait_for(ws.recv(), timeout=timeout)
            out.append(json.loads(raw))
        except (asyncio.TimeoutError, websockets.ConnectionClosed):
            return out


def types(msgs: list[dict]) -> list[str]:
    return [m.get("type") for m in msgs]


async def scenario() -> None:
    async with websockets.connect(URL) as a, \
               websockets.connect(URL) as b, \
               websockets.connect(URL) as c:
        await asyncio.sleep(0.2)
        for ws in (a, b, c):
            await drain(ws, 0.1)

        print("\n[1] call_request — 로비 전체에 전달")
        await a.send(json.dumps({"type": "call_request"}))
        mb, mc = await drain(b), await drain(c)
        check("call_request" in types(mb), "B가 call_request 수신")
        check("call_request" in types(mc), "C도 call_request 수신 (주소 지정 없음 — 알려진 한계)")

        print("\n[2] call_accept — 세션 성립")
        await b.send(json.dumps({"type": "call_accept"}))
        ma, mb, mc = await drain(a), await drain(b), await drain(c)
        check("call_accept" in types(ma), "A가 call_accept 수신")
        check("session_start" in types(ma), "A가 session_start 수신")
        check("session_start" in types(mb), "B가 session_start 수신")
        check(mc == [], "C는 아무것도 못 받음")

        sid_a = next(m["session_id"] for m in ma if m["type"] == "session_start")
        sid_b = next(m["session_id"] for m in mb if m["type"] == "session_start")
        role_a = next(m["role"] for m in ma if m["type"] == "session_start")
        role_b = next(m["role"] for m in mb if m["type"] == "session_start")
        check(sid_a == sid_b, f"양쪽 session_id 일치 ({sid_a})")
        check({role_a, role_b} == {"caller", "callee"}, f"역할 부여 ({role_a}/{role_b})")

        print("\n[3] SDP/ICE — 세션 내부에서만 오간다")
        await a.send(json.dumps({"type": "offer", "sdp": "v=0 FAKE_OFFER"}))
        mb, mc = await drain(b), await drain(c)
        check("offer" in types(mb), "B가 offer 수신")
        check(mc == [], "C에게 offer 유출 없음")

        await b.send(json.dumps({"type": "answer", "sdp": "v=0 FAKE_ANSWER"}))
        ma, mc = await drain(a), await drain(c)
        check("answer" in types(ma), "A가 answer 수신")
        check(mc == [], "C에게 answer 유출 없음")

        await a.send(json.dumps({"type": "ice", "candidate": "cand", "sdpMid": "0",
                                 "sdpMLineIndex": 0}))
        mb, mc = await drain(b), await drain(c)
        got = next((m for m in mb if m["type"] == "ice"), None)
        check(got is not None and got.get("candidate") == "cand", "ice 필드 보존")
        check(mc == [], "C에게 ice 유출 없음")

        print("\n[4] hang_up — 세션 종료")
        await a.send(json.dumps({"type": "hang_up"}))
        ma, mb, mc = await drain(a), await drain(b), await drain(c)
        check("hang_up" in types(mb), "B가 hang_up 수신")
        check("session_end" in types(ma) and "session_end" in types(mb),
              "양쪽 session_end 수신")
        check(mc == [], "C는 통화 종료도 못 봄")

        print("\n[5] 연결 끊김 — 상대에게 통보")
        await a.send(json.dumps({"type": "call_request"}))
        await drain(b)
        await b.send(json.dumps({"type": "call_accept"}))
        await drain(a); await drain(b)
        await a.close()
        await asyncio.sleep(0.3)
        mb = await drain(b)
        check("hang_up" in types(mb), "상대 연결 종료 시 hang_up 통보")
        check("session_end" in types(mb), "상대 연결 종료 시 session_end 통보")


async def main() -> int:
    proc = subprocess.Popen(
        [sys.executable, "-m", "uvicorn", "main:app",
         "--host", "127.0.0.1", "--port", str(PORT), "--log-level", "error"],
        cwd=SERVER_DIR, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        for _ in range(50):                       # 기동 대기
            try:
                async with websockets.connect(URL) as ws:
                    await ws.close()
                break
            except Exception:
                await asyncio.sleep(0.2)
        else:
            print("서버 기동 실패:", proc.stderr.read().decode()[-500:])
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
