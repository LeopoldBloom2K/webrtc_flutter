"""통화 음성 중계 채널 — 서버가 보호한 음성을 상대방에게 넘긴다.

    폰A 마이크 ─PCM16─▶ /audio(caller) ─VocalCrypt─▶ /audio(callee) ─▶ 폰B 스피커
    폰B 마이크 ─PCM16─▶ /audio(callee) ─VocalCrypt─▶ /audio(caller) ─▶ 폰A 스피커

상대방이 듣는 소리는 언제나 서버에서 보호된 음성이다. 통화 음성은 WebRTC 를
거치지 않는다.

흐름
  1) ws://host:8080/audio 접속
  2) 첫 프레임은 텍스트(JSON) 핸드셰이크
       {"session_id": "...", "role": "caller"|"callee",
        "sample_rate": 16000, "target_snr": 22.0}
     서버는 {"type":"audio_ready", ...} 로 응답한다.
  3) 이후 내가 보내는 바이너리 프레임 = 내 마이크, 16-bit little-endian PCM 모노.
     내가 받는 바이너리 프레임 = **상대방**의 보호된 음성, 같은 형식.
     상대방 채널이 아직 열리지 않았으면 그 사이 프레임은 버린다(연결 직후의 짧은 구간).

주의 (측정으로 확인된 제약)
  - 알고리즘이 청크마다 F0 를 새로 추정하고 피크 정규화를 다시 하므로 청크 경계에서
    노이즈 성분이 불연속이 된다. 100ms 청크에서 경계 점프가 청크 내부의 약 2.4배,
    신호 대비 약 -32dB 이다. 짧을수록 심해진다(20ms 에서 5.5배).
  - 프레임당 처리 시간은 고정비가 대부분이다. 100ms 청크면 RTF 0.12 안팎으로 여유가 있다.
"""
from __future__ import annotations

import asyncio
import json
import logging
import time

import numpy as np
from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from auth import check_ws
from config import settings
from protect import vocalcrypt_v3_protect
from signaling import manager

log = logging.getLogger("audio")
router = APIRouter()

ALLOWED_RATES = {8000, 16000, 24000, 48000}
OTHER = {"caller": "callee", "callee": "caller"}

# 세션별로 열려 있는 오디오 채널. session_id -> {role: WebSocket}
_channels: dict[str, dict[str, WebSocket]] = {}

# 이 길이(초)만큼 오디오가 지날 때마다 방향별 레벨을 한 줄 남긴다.
LOG_EVERY_S = 2.0


def _process(pcm: bytes, sr: int, target_snr: float) -> bytes:
    """PCM16 -> VocalCrypt -> PCM16. 이벤트 루프 밖(스레드)에서 실행한다."""
    audio = np.frombuffer(pcm, dtype="<i2").astype(np.float64) / 32768.0
    if audio.size == 0:
        return pcm
    out = vocalcrypt_v3_protect(audio, sr, target_snr=target_snr, verbose=False)
    out = np.clip(out, -1.0, 1.0)
    return (out * 32767.0).astype("<i2").tobytes()


def _dbfs(x: float) -> float:
    return 20.0 * np.log10(x) if x > 0.0 else -999.0


class _Window:
    """한 방향의 레벨·처리 시간을 LOG_EVERY_S 동안 모은다.

    입력 peak 와 RMS 를 함께 남기는 이유: 둘의 차이(crest factor)가 3~4dB 면
    목소리가 아니라 연속 톤이 들어오고 있는 것이다(정상 음성은 15dB 이상).
    """

    def __init__(self) -> None:
        self.reset()

    def reset(self) -> None:
        self.samples = 0
        self.in_sq = 0.0
        self.in_peak = 0
        self.out_sq = 0.0
        self.proc_ms = 0.0
        self.frames = 0

    def add(self, pcm: bytes, out: bytes, proc_ms: float) -> None:
        a = np.frombuffer(pcm, dtype="<i2").astype(np.float64)
        b = np.frombuffer(out, dtype="<i2").astype(np.float64)
        self.samples += a.size
        self.in_sq += float(np.dot(a, a))
        self.in_peak = max(self.in_peak, int(np.max(np.abs(a))) if a.size else 0)
        self.out_sq += float(np.dot(b, b))
        self.proc_ms += proc_ms
        self.frames += 1

    def line(self) -> str:
        n = max(self.samples, 1)
        rms_in = np.sqrt(self.in_sq / n) / 32768.0
        rms_out = np.sqrt(self.out_sq / n) / 32768.0
        return (f"입력 RMS {_dbfs(rms_in):6.1f} / peak {_dbfs(self.in_peak / 32768.0):5.1f} dBFS  "
                f"출력 RMS {_dbfs(rms_out):6.1f} dBFS  "
                f"처리 {self.proc_ms / max(self.frames, 1):5.1f}ms/프레임")


@router.websocket("/audio")
async def audio_channel(ws: WebSocket) -> None:
    await ws.accept()
    if not await check_ws(ws):
        return
    try:
        hello = json.loads(await ws.receive_text())
    except Exception:
        await ws.close(code=1003, reason="handshake must be JSON")
        return

    session_id = hello.get("session_id")
    sr = int(hello.get("sample_rate", 16000))
    target_snr = float(hello.get("target_snr", 22.0))
    role = hello.get("role")

    if manager.get(session_id) is None:
        await ws.close(code=1008, reason="unknown session_id")
        log.warning("[!] audio: 알 수 없는 session_id=%r", session_id)
        return
    if role not in OTHER:
        await ws.close(code=1003, reason="role must be caller or callee")
        return
    if sr not in ALLOWED_RATES:
        await ws.close(code=1003, reason=f"unsupported sample_rate {sr}")
        return

    # audio_ready 를 먼저 보내고 나서 등록한다. 반대로 하면 상대가 보낸 음성
    # 프레임이 audio_ready 보다 먼저 도착해 클라이언트 핸드셰이크가 꼬일 수 있다.
    await ws.send_json({"type": "audio_ready", "session_id": session_id,
                        "sample_rate": sr, "target_snr": target_snr})
    slots = _channels.setdefault(session_id, {})
    slots[role] = ws
    direction = f"{role}→{OTHER[role]}"
    log.info("[+] audio %s/%s  sr=%d snr=%.1f", session_id, role, sr, target_snr)

    frames = relayed = dropped = 0
    total_samples = 0
    total_ms = 0.0
    win = _Window()
    try:
        while True:
            pcm = await ws.receive_bytes()
            if len(pcm) > settings.max_frame_bytes:
                await ws.close(code=1009, reason="frame too large")
                return
            t0 = time.perf_counter()
            out = await asyncio.to_thread(_process, pcm, sr, target_snr)
            ms = (time.perf_counter() - t0) * 1000.0
            total_ms += ms
            frames += 1
            total_samples += len(pcm) // 2

            peer = slots.get(OTHER[role])
            if peer is None:
                dropped += 1
            else:
                try:
                    await peer.send_bytes(out)
                    relayed += 1
                except Exception:            # 상대가 막 끊긴 경우
                    dropped += 1

            win.add(pcm, out, ms)
            if win.samples >= LOG_EVERY_S * sr:
                log.info("    audio %s %s  %s  중계 %d / 버림 %d",
                         session_id, direction, win.line(), relayed, dropped)
                win.reset()
    except WebSocketDisconnect:
        pass
    except Exception as e:
        log.warning("[!] audio %s/%s: %s", session_id, role, e)
    finally:
        if slots.get(role) is ws:
            del slots[role]
        if not slots:
            _channels.pop(session_id, None)
        dur = total_samples / sr if sr else 0.0
        rtf = (total_ms / 1000.0 / dur) if dur > 0 else float("nan")
        log.info("[-] audio %s/%s  frames=%d 중계=%d 버림=%d  audio=%.2fs  "
                 "proc=%.0fms  RTF=%.3f",
                 session_id, role, frames, relayed, dropped, dur, total_ms, rtf)
