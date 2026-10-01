"""통화 세션 — 시그널링과 탐지를 같은 식별자로 묶는다.

세션은 call_request → call_accept 쌍이 성립할 때 생성되고,
hang_up / call_reject / call_cancel / 연결 종료로 소멸한다.
"""
from __future__ import annotations

import time
import uuid
from collections import deque
from dataclasses import dataclass, field


@dataclass
class Peer:
    id: str
    ws: object                       # WebSocket
    session_id: str | None = None
    calling: bool = False            # call_request 발신 후 응답 대기 중


# 사용자에게 노출되는 상태. 청크 하나가 아니라 누적 결과로만 바뀐다.
ANALYZING = "analyzing"
HUMAN = "human"
AI_SUSPECTED = "ai_suspected"
AI_DETECTED = "ai_detected"


def _defaults() -> dict:
    """보정 파일이 있으면 창 길이와 임계값을 거기서 읽는다."""
    try:
        import json
        from pathlib import Path
        c = json.loads((Path(__file__).parent / "detect" / "calibration.json")
                       .read_text(encoding="utf-8"))
        return {"window": int(c["window"]), "suspect_at": float(c["suspect_at"]),
                "detect_at": float(c["detect_at"]), "hold_chunks": int(c["hold_chunks"])}
    except Exception:
        return {}


_D = _defaults()


@dataclass
class Track:
    """한 방향(발신자 또는 수신자)의 탐지 누적 상태.

    청크 단위 점수는 흔들리므로 창(window) 평균으로만 상태를 바꾼다.
    창 길이와 임계값은 실측 점수 분포로 다시 잡아야 하는 값이다.
    """
    window: int = _D.get("window", 5)              # 창 길이 (청크 개수)
    suspect_at: float = _D.get("suspect_at", 0.60)  # 창 평균이 넘으면 의심
    detect_at: float = _D.get("detect_at", 0.80)    # 넘고 hold 유지되면 확정
    hold_chunks: int = _D.get("hold_chunks", 3)
    scores: deque = field(default_factory=lambda: deque(maxlen=64))
    state: str = ANALYZING
    _above: int = 0

    def push(self, p_spoof: float) -> str:
        self.scores.append(float(p_spoof))
        if len(self.scores) < self.window:
            self.state = ANALYZING
            return self.state
        recent = list(self.scores)[-self.window:]
        avg = sum(recent) / len(recent)
        if avg >= self.detect_at:
            self._above += 1
        else:
            self._above = 0
        if self._above >= self.hold_chunks:
            self.state = AI_DETECTED          # 확정은 되돌리지 않는다
        elif self.state != AI_DETECTED:
            self.state = AI_SUSPECTED if avg >= self.suspect_at else HUMAN
        return self.state

    @property
    def mean(self) -> float:
        if not self.scores:
            return 0.0
        recent = list(self.scores)[-self.window:]
        return sum(recent) / len(recent)


@dataclass
class Session:
    id: str
    caller_id: str
    callee_id: str
    created_at: float = field(default_factory=time.time)
    tracks: dict[str, Track] = field(default_factory=dict)

    def track(self, role: str) -> Track:
        if role not in self.tracks:
            self.tracks[role] = Track()
        return self.tracks[role]

    def other(self, peer_id: str) -> str | None:
        if peer_id == self.caller_id:
            return self.callee_id
        if peer_id == self.callee_id:
            return self.caller_id
        return None


class SessionManager:
    def __init__(self) -> None:
        self.peers: dict[str, Peer] = {}
        self.sessions: dict[str, Session] = {}

    def add_peer(self, ws) -> Peer:
        peer = Peer(id=uuid.uuid4().hex[:8], ws=ws)
        self.peers[peer.id] = peer
        return peer

    def drop_peer(self, peer_id: str) -> Session | None:
        """피어를 제거하고, 통화 중이었다면 그 세션을 돌려준다."""
        peer = self.peers.pop(peer_id, None)
        if peer is None or peer.session_id is None:
            return None
        return self.sessions.get(peer.session_id)

    def lobby(self, exclude_id: str) -> list[Peer]:
        """아직 통화에 묶이지 않은 다른 피어들."""
        return [p for p in self.peers.values()
                if p.id != exclude_id and p.session_id is None]

    def find_caller(self, exclude_id: str) -> Peer | None:
        """call_request를 보내고 응답을 기다리는 피어."""
        for p in self.lobby(exclude_id):
            if p.calling:
                return p
        return None

    def pair(self, caller: Peer, callee: Peer) -> Session:
        s = Session(id=uuid.uuid4().hex[:12],
                    caller_id=caller.id, callee_id=callee.id)
        self.sessions[s.id] = s
        for p in (caller, callee):
            p.session_id = s.id
            p.calling = False
        return s

    def end(self, session_id: str) -> Session | None:
        s = self.sessions.pop(session_id, None)
        if s is None:
            return None
        for pid in (s.caller_id, s.callee_id):
            p = self.peers.get(pid)
            if p is not None:
                p.session_id = None
                p.calling = False
        return s

    def get(self, session_id: str | None) -> Session | None:
        return self.sessions.get(session_id) if session_id else None
