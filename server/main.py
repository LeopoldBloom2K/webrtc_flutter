"""VoiceGuard 서버 — 시그널링·세션·VocalCrypt 를 한 프로세스에서 다룬다.

실행:
  pip install -r requirements.txt
  python main.py                 # 0.0.0.0:8080

엔드포인트
  WS   /           시그널링 (기존 8종 프로토콜 + session_start/end)
  WS   /audio      오디오 패킷 채널 (세션에 묶인 PCM16 스트림)
  POST /protect    WAV 한 개를 VocalCrypt 처리 (기존 :8765 계약과 동일)
  POST /detect     청크 채점 + 세션 누적 상태 갱신
  GET  /health     상태

Android 에뮬레이터: ws://10.0.2.2:8080 , http://10.0.2.2:8080
"""
from __future__ import annotations

import logging
import time

import anyio
import uvicorn
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

import audio
import protect
import signaling
from config import settings
from detect import api as detect_api
from protect import api as protect_api

logging.basicConfig(level=getattr(logging, settings.log_level, logging.INFO),
                    format="%(asctime)s  %(message)s", datefmt="%H:%M:%S")
log = logging.getLogger("main")

app = FastAPI(title="VoiceGuard Server")

if settings.allowed_origins:
    app.add_middleware(CORSMiddleware, allow_origins=list(settings.allowed_origins),
                       allow_methods=["GET", "POST"], allow_headers=["*"])


@app.on_event("startup")
async def _startup() -> None:
    # /protect, /detect 는 동기 엔드포인트라 anyio 스레드풀에서 돈다.
    # 기본값(40)은 CPU 바운드 작업에 과하다 — CPU 수만큼으로 줄여 경합을 막는다.
    anyio.to_thread.current_default_thread_limiter().total_tokens = settings.threads
    log.info("VoiceGuard 서버 :%d  인증=%s  스레드=%d",
             settings.port, "on" if settings.auth_enabled else "OFF(로컬)",
             settings.threads)
    if not settings.auth_enabled:
        log.warning("VOICEGUARD_AUTH_TOKEN 이 없습니다 — 누구나 접속할 수 있습니다")
    # 통화 경로에 들어가는 알고리즘이 어느 파일의 어느 판인지 기동할 때마다 남긴다.
    src = protect.SOURCE
    log.info("VocalCrypt 원본 연결: %s/%s  (수정 %s)", src.parent.name, src.name,
             time.strftime("%m-%d %H:%M", time.localtime(src.stat().st_mtime)))
app.include_router(signaling.router)
app.include_router(audio.router)
app.include_router(protect_api.router)
app.include_router(detect_api.router)


@app.get("/health")
async def health() -> dict:
    return {
        "status": "ok",
        "peers": len(signaling.manager.peers),
        "sessions": len(signaling.manager.sessions),
    }


if __name__ == "__main__":
    # 워커는 반드시 1개. 세션 상태가 프로세스 메모리에 있어서, 워커가 여러 개면
    # 1번 워커에서 만든 세션을 2번 워커가 모른다(/detect 가 404).
    uvicorn.run(app, host=settings.host, port=settings.port, workers=1,
                log_level="warning")
