"""/detect — 청크 하나를 채점하고 세션 상태를 갱신한다.

요청  : multipart/form-data
          file        WAV 청크 (모노 권장)
          session_id  시그널링에서 받은 session_start.session_id
          role        caller | callee  (어느 방향의 음성인지)
응답  : JSON

설계 원칙
  - 청크 하나로 이진 판정을 내리지 않는다. p_spoof 는 점수일 뿐이고,
    사용자에게 보여줄 state 는 창 평균으로만 바뀐다.
  - 누적 상태는 세션에 있다. 서버가 상태를 들고 있으므로 클라이언트는
    매 청크를 그냥 올리기만 하면 된다.
"""
from __future__ import annotations

import logging
import time

import numpy as np
from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile

import wavio
from auth import require_http
from config import settings
from signaling import manager

from . import DEFAULT

log = logging.getLogger("detect")
router = APIRouter(prefix="/detect", tags=["detect"],
                   dependencies=[Depends(require_http)])


def _decode(raw: bytes) -> tuple[int, np.ndarray]:
    try:
        sr, audio = wavio.read(raw)
    except Exception as e:
        raise HTTPException(400, f"WAV 파싱 실패: {e}") from e
    if audio.ndim > 1:
        audio = audio[:, 0]
    if audio.size == 0:
        raise HTTPException(400, "빈 오디오")
    return sr, audio


@router.post("")
def detect(file: UploadFile = File(...),
           session_id: str = Form(...),
           role: str = Form(default="callee")) -> dict:
    session = manager.get(session_id)
    if session is None:
        raise HTTPException(404, f"알 수 없는 session_id: {session_id}")
    if role not in ("caller", "callee"):
        raise HTTPException(400, "role 은 caller 또는 callee")

    raw = file.file.read(settings.max_upload_bytes + 1)
    if len(raw) > settings.max_upload_bytes:
        raise HTTPException(413, "청크가 너무 큽니다")

    sr, audio = _decode(raw)
    t0 = time.perf_counter()
    p_spoof, feats = DEFAULT.score(audio, sr)
    latency_ms = (time.perf_counter() - t0) * 1000.0

    track = session.track(role)
    state = track.push(p_spoof)

    log.info("detect %s/%-6s p=%.3f avg=%.3f %-12s %.1fms",
             session_id, role, p_spoof, track.mean, state, latency_ms)

    return {
        "session_id": session_id,
        "role": role,
        "p_spoof": round(p_spoof, 4),
        "state": state,
        "window_mean": round(track.mean, 4),
        "chunks": len(track.scores),
        "scorer": DEFAULT.name,
        "calibrated": DEFAULT.calibrated,   # False = 점수 절대값을 신뢰하지 말 것
        "latency_ms": round(latency_ms, 2),
        "features": {k: round(v, 5) for k, v in feats.items()},
    }
