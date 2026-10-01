"""실행 설정 — 환경변수로만 바꾼다. 기본값은 로컬 개발 기준이다.

로컬에서는 아무것도 설정하지 않아도 지금까지와 똑같이 돈다.
배포에서는 최소한 VOICEGUARD_AUTH_TOKEN 을 설정해야 한다.

  VOICEGUARD_HOST            bind 주소            (기본 0.0.0.0)
  VOICEGUARD_PORT            포트                 (기본 8080)
  VOICEGUARD_AUTH_TOKEN      공유 토큰. 비우면 인증 없음 (로컬 전용)
  VOICEGUARD_ALLOWED_ORIGINS 쉼표 구분 CORS 출처. 기본 없음
  VOICEGUARD_MAX_UPLOAD_MB   업로드 상한          (기본 32)
  VOICEGUARD_MAX_FRAME_MB    오디오 프레임 상한   (기본 4)
  VOICEGUARD_LOG_LEVEL       INFO / WARNING / ...  (기본 INFO)
  VOICEGUARD_THREADS         무거운 연산용 스레드 수 (기본 CPU 수, 최대 8)
"""
from __future__ import annotations

import os
from dataclasses import dataclass


def _int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, default))
    except ValueError:
        return default


@dataclass(frozen=True)
class Settings:
    host: str = os.environ.get("VOICEGUARD_HOST", "0.0.0.0")
    port: int = _int("VOICEGUARD_PORT", 8080)
    auth_token: str = os.environ.get("VOICEGUARD_AUTH_TOKEN", "")
    allowed_origins: tuple[str, ...] = tuple(
        o.strip() for o in os.environ.get("VOICEGUARD_ALLOWED_ORIGINS", "").split(",")
        if o.strip())
    max_upload_bytes: int = _int("VOICEGUARD_MAX_UPLOAD_MB", 32) * 1024 * 1024
    max_frame_bytes: int = _int("VOICEGUARD_MAX_FRAME_MB", 4) * 1024 * 1024
    log_level: str = os.environ.get("VOICEGUARD_LOG_LEVEL", "INFO").upper()
    threads: int = min(_int("VOICEGUARD_THREADS", os.cpu_count() or 4), 8)

    @property
    def auth_enabled(self) -> bool:
        return bool(self.auth_token)


settings = Settings()
