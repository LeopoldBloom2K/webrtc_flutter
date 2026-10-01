"""WebSocket 시그널링.

기존 Node 서버(server.js)의 메시지 8종을 그대로 받는다:
  call_request / call_accept / call_reject / call_cancel / hang_up
  offer {sdp} / answer {sdp} / ice {candidate, sdpMid, sdpMLineIndex}

달라진 점:
  - 전원 브로드캐스트 -> 세션 단위 중계. 통화가 성립하면 제3자에게 SDP가 새지 않는다.
  - 통화 성립 시 session_start, 종료 시 session_end 를 추가로 내려보낸다.
    (기존 클라이언트는 모르는 type 이므로 무시된다 — 하위 호환)
"""
from __future__ import annotations

import logging

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from auth import check_ws
from session import Peer, Session, SessionManager

log = logging.getLogger("signaling")
router = APIRouter()
manager = SessionManager()

CONTROL = {"call_request", "call_accept", "call_reject", "call_cancel", "hang_up"}
RTC = {"offer", "answer", "ice"}
ALLOWED = CONTROL | RTC
END_TYPES = {"hang_up", "call_reject", "call_cancel"}


async def _send(peer: Peer | None, payload: dict) -> None:
    if peer is None:
        return
    try:
        await peer.ws.send_json(payload)
    except Exception:
        pass


@router.websocket("/")
async def endpoint(ws: WebSocket) -> None:
    await ws.accept()
    if not await check_ws(ws):
        return
    peer = manager.add_peer(ws)
    log.info("[+] %s connected (peers=%d)", peer.id, len(manager.peers))
    try:
        while True:
            msg = await ws.receive_json()
            if isinstance(msg, dict):
                await _handle(peer, msg)
    except WebSocketDisconnect:
        pass
    except Exception as e:
        log.warning("[!] %s: %s", peer.id, e)
    finally:
        await _cleanup(peer)


async def _handle(peer: Peer, msg: dict) -> None:
    mtype = msg.get("type")
    if mtype not in ALLOWED:
        log.warning("[?] %s unknown type=%r", peer.id, mtype)
        return
    if peer.session_id:
        await _in_session(peer, mtype, msg)
    else:
        await _in_lobby(peer, mtype, msg)


async def _in_session(peer: Peer, mtype: str, msg: dict) -> None:
    session = manager.get(peer.session_id)
    if session is None:                      # 세션이 이미 정리된 경우
        peer.session_id = None
        return
    other = manager.peers.get(session.other(peer.id) or "")
    await _send(other, msg)
    log.info("[>] %-13s %s -> %s", mtype, peer.id, other.id if other else "-")
    if mtype in END_TYPES:
        await _end(session, reason=mtype)


async def _in_lobby(peer: Peer, mtype: str, msg: dict) -> None:
    if mtype == "call_request":
        peer.calling = True
        targets = manager.lobby(peer.id)
        for other in targets:
            await _send(other, msg)
        log.info("[>] call_request   %s -> lobby(%d)", peer.id, len(targets))
        return

    if mtype == "call_accept":
        caller = manager.find_caller(peer.id)
        if caller is None:
            log.info("[!] %s call_accept 이지만 대기 중인 발신자 없음", peer.id)
            return
        session = manager.pair(caller, peer)
        await _send(caller, msg)             # 기존 흐름 유지: 발신자가 accept 를 받는다
        await _send(caller, {"type": "session_start",
                             "session_id": session.id, "role": "caller"})
        await _send(peer, {"type": "session_start",
                           "session_id": session.id, "role": "callee"})
        log.info("[*] session %s  caller=%s callee=%s", session.id, caller.id, peer.id)
        return

    if mtype in ("call_reject", "call_cancel"):
        peer.calling = False
        for other in manager.lobby(peer.id):
            await _send(other, msg)
        log.info("[>] %-13s %s -> lobby", mtype, peer.id)
        return

    # offer/answer/ice 는 세션 성립 전에 올 수 없다
    log.warning("[!] %s %s (세션 없음) — 버림", peer.id, mtype)


async def _end(session: Session, reason: str) -> None:
    for pid in (session.caller_id, session.callee_id):
        await _send(manager.peers.get(pid),
                    {"type": "session_end",
                     "session_id": session.id, "reason": reason})
    manager.end(session.id)
    log.info("[*] session %s 종료 (%s)", session.id, reason)


async def _cleanup(peer: Peer) -> None:
    session = manager.drop_peer(peer.id)
    if session is not None:
        other = manager.peers.get(session.other(peer.id) or "")
        await _send(other, {"type": "hang_up"})   # 기존 클라이언트가 아는 형태로 먼저 알림
        await _end(session, reason="peer_disconnected")
    log.info("[-] %s disconnected (peers=%d)", peer.id, len(manager.peers))
