"""공유 토큰 인증.

VOICEGUARD_AUTH_TOKEN 이 비어 있으면 검사하지 않는다(로컬 개발).
설정되어 있으면 모든 경로에서 요구한다.

  HTTP : Authorization: Bearer <token>
  WS   : ?token=<token>  또는 같은 Authorization 헤더

공유 토큰은 "앱을 쓰는 클라이언트인가"만 증명한다. **누가** 쓰는지는 증명하지
않으므로 계정 단위 대응(신고·차단 등)에는 부족하다. 사용자 인증은 별도다.
"""
from __future__ import annotations

import hmac

from fastapi import HTTPException, Request, WebSocket

from config import settings


def _match(given: str) -> bool:
    # 타이밍 차이로 토큰을 알아내지 못하도록 상수 시간 비교
    return hmac.compare_digest(given or "", settings.auth_token)


def _from_header(value: str | None) -> str:
    if not value:
        return ""
    parts = value.split(None, 1)
    return parts[1].strip() if len(parts) == 2 and parts[0].lower() == "bearer" else ""


def require_http(request: Request) -> None:
    """HTTP 엔드포인트 의존성."""
    if not settings.auth_enabled:
        return
    if not _match(_from_header(request.headers.get("authorization"))):
        raise HTTPException(401, "invalid or missing token")


async def check_ws(ws: WebSocket) -> bool:
    """WebSocket 수락 전 검사. 실패하면 닫고 False 를 돌려준다."""
    if not settings.auth_enabled:
        return True
    token = (ws.query_params.get("token")
             or _from_header(ws.headers.get("authorization")))
    if _match(token):
        return True
    await ws.close(code=1008, reason="unauthorized")
    return False
