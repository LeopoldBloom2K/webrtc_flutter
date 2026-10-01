"""VocalCrypt HTTP 엔드포인트.

기존 vocalcrypt_server.py(:8765) 의 /protect 계약을 그대로 유지한다.
  요청  : multipart/form-data  file=<WAV>, target_snr=<float>
  응답  : audio/wav

기존 구현과 달라진 점
  1. 알고리즘을 복사하지 않고 protect 패키지에서 import 한다.
     (원본은 server.py 쪽에 함수가 복제되어 이미 갈라져 있었다)
  2. `async def` 가 아니라 `def` 로 선언한다. FastAPI 가 동기 엔드포인트를
     스레드풀로 넘기므로, 무거운 numpy 연산이 시그널링 WebSocket 을 막지 않는다.
  3. 입력 검증과 크기 제한을 둔다. 실패는 조용히 넘기지 않고 HTTP 오류로 알린다.
"""
from __future__ import annotations

import logging
import time

import numpy as np
from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile
from fastapi.responses import Response

import wavio
from auth import require_http
from config import settings

from . import vocalcrypt_v3_protect

log = logging.getLogger("protect")
router = APIRouter(prefix="/protect", tags=["protect"],
                   dependencies=[Depends(require_http)])


ALLOWED_RATES = {8000, 16000, 22050, 24000, 44100, 48000}


def _decode(raw: bytes) -> tuple[int, np.ndarray]:
    """WAV 바이트 -> (샘플레이트, 모노 float64). 실패는 400 으로 알린다."""
    try:
        sr, audio = wavio.read(raw)
    except Exception as e:
        raise HTTPException(400, f"WAV 파싱 실패: {e}") from e
    if sr not in ALLOWED_RATES:
        raise HTTPException(400, f"지원하지 않는 샘플레이트: {sr}")
    if audio.ndim > 1:
        audio = audio[:, 0]
    if audio.size == 0:
        raise HTTPException(400, "빈 오디오")
    return sr, audio


@router.post("")
def protect(file: UploadFile = File(...),
            target_snr: float = Form(default=22.0)) -> Response:
    if not 0.0 < target_snr <= 60.0:
        raise HTTPException(400, "target_snr 범위는 (0, 60] 입니다")

    raw = file.file.read(settings.max_upload_bytes + 1)
    if len(raw) > settings.max_upload_bytes:
        raise HTTPException(413, "파일이 너무 큽니다")

    sr, audio = _decode(raw)
    t0 = time.perf_counter()
    protected = vocalcrypt_v3_protect(audio, sr, target_snr=target_snr, verbose=False)
    elapsed_ms = (time.perf_counter() - t0) * 1000.0
    dur_s = len(audio) / sr

    # 실측 SNR 을 헤더로 돌려준다. 기기에서 녹음-보호가 실제로 됐는지
    # 앱이 따로 계산하지 않고 확인할 수 있어야 한다.
    m = min(len(audio), len(protected))
    diff = protected[:m] - audio[:m]
    measured_snr = float(10.0 * np.log10(
        np.mean(audio[:m] ** 2) / (np.mean(diff ** 2) + 1e-20)))
    # 입력의 절대 레벨. measured_snr 은 신호 대비 상대값이라 무음이 들어와도
    # 목표치를 맞춘다. 기기 마이크가 실제로 소리를 잡았는지는 이 값으로만 가려진다.
    rms = float(np.sqrt(np.mean(audio ** 2)))
    peak = float(np.max(np.abs(audio)))
    rms_dbfs = 20.0 * np.log10(rms) if rms > 0.0 else -999.0
    peak_dbfs = 20.0 * np.log10(peak) if peak > 0.0 else -999.0

    log.info("protect  %.2fs @%dHz  입력 RMS %.1f / peak %.1f dBFS  "
             "목표 %.1fdB / 실측 %.1fdB  %.0fms (RTF %.3f)",
             dur_s, sr, rms_dbfs, peak_dbfs, target_snr, measured_snr, elapsed_ms,
             elapsed_ms / 1000.0 / dur_s)

    return Response(
        content=wavio.to_bytes(sr, protected),
        media_type="audio/wav",
        headers={
            "Content-Disposition": "attachment; filename=protected.wav",
            "X-Processing-Ms": f"{elapsed_ms:.1f}",
            "X-Audio-Seconds": f"{dur_s:.3f}",
            "X-Sample-Rate": str(sr),
            "X-Measured-Snr": f"{measured_snr:.2f}",
            "X-Input-Rms-Dbfs": f"{rms_dbfs:.2f}",
            "X-Input-Peak-Dbfs": f"{peak_dbfs:.2f}",
        },
    )
