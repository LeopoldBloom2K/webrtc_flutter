"""WAV 입출력 — 표준 라이브러리와 numpy 만 쓴다.

scipy.io.wavfile 을 쓰지 않는 이유
  scipy.io 는 __init__ 에서 MATLAB 지원을 끌어오고, 그게 scipy.sparse 전체를
  불러온다. macOS 27 에서는 그 경로 끝의 _propack 바이너리를 dyld 가 거부해
  서버가 기동조차 못 했다(scipy 1.15.x). 정작 필요한 건 WAV 읽기/쓰기뿐이고
  신호처리에 쓰는 scipy.signal 은 그 경로를 타지 않는다.

  표준 wave 모듈은 IEEE float WAV(포맷 3)를 못 읽으므로, RIFF 청크를 직접
  훑어 PCM 정수와 float 양쪽을 처리한다.
"""
from __future__ import annotations

import io
import struct
from pathlib import Path

import numpy as np

PCM = 1
IEEE_FLOAT = 3
EXTENSIBLE = 0xFFFE


class WavError(ValueError):
    pass


def _chunks(buf: bytes):
    if len(buf) < 12 or buf[:4] != b"RIFF" or buf[8:12] != b"WAVE":
        raise WavError("RIFF/WAVE 헤더가 아닙니다")
    pos = 12
    while pos + 8 <= len(buf):
        cid = buf[pos:pos + 4]
        size = struct.unpack_from("<I", buf, pos + 4)[0]
        body = buf[pos + 8:pos + 8 + size]
        yield cid, body
        pos += 8 + size + (size & 1)          # 청크는 짝수 경계로 패딩된다


def read(source: bytes | str | Path) -> tuple[int, np.ndarray]:
    """WAV 바이트 또는 파일 경로를 (샘플레이트, float64 배열) 로 읽는다.

    다채널이면 (샘플수, 채널수) 형태로 돌려준다. 값 범위는 [-1, 1).
    """
    buf = Path(source).read_bytes() if isinstance(source, (str, Path)) else source

    fmt = data = None
    for cid, body in _chunks(buf):
        if cid == b"fmt " and fmt is None:
            fmt = body
        elif cid == b"data" and data is None:
            data = body
    if fmt is None or data is None:
        raise WavError("fmt 또는 data 청크가 없습니다")
    if len(fmt) < 16:
        raise WavError("fmt 청크가 짧습니다")

    audio_format, channels, rate, _, _, bits = struct.unpack_from("<HHIIHH", fmt, 0)
    if audio_format == EXTENSIBLE:
        # SubFormat GUID 의 앞 2바이트가 실제 포맷 코드를 그대로 담고 있다
        if len(fmt) < 26:
            raise WavError("EXTENSIBLE 인데 SubFormat 이 없습니다")
        audio_format = struct.unpack_from("<H", fmt, 24)[0]
    if channels < 1:
        raise WavError("채널 수가 0 입니다")

    if audio_format == PCM:
        if bits == 8:                              # 8비트는 부호 없음
            x = np.frombuffer(data, dtype=np.uint8).astype(np.float64)
            x = (x - 128.0) / 128.0
        elif bits == 16:
            x = np.frombuffer(data, dtype="<i2").astype(np.float64) / 32768.0
        elif bits == 24:
            raw = np.frombuffer(data[:len(data) // 3 * 3], dtype=np.uint8)
            raw = raw.reshape(-1, 3).astype(np.int32)
            v = raw[:, 0] | (raw[:, 1] << 8) | (raw[:, 2] << 16)
            v = np.where(v & 0x800000, v - 0x1000000, v)
            x = v.astype(np.float64) / 8388608.0
        elif bits == 32:
            x = np.frombuffer(data, dtype="<i4").astype(np.float64) / 2147483648.0
        else:
            raise WavError(f"지원하지 않는 비트 심도: {bits}")
    elif audio_format == IEEE_FLOAT:
        if bits == 32:
            x = np.frombuffer(data, dtype="<f4").astype(np.float64)
        elif bits == 64:
            x = np.frombuffer(data, dtype="<f8").astype(np.float64)
        else:
            raise WavError(f"지원하지 않는 float 비트 심도: {bits}")
    else:
        raise WavError(f"지원하지 않는 WAV 포맷 코드: {audio_format}")

    if channels > 1:
        usable = len(x) // channels * channels
        x = x[:usable].reshape(-1, channels)
    return int(rate), x


def to_bytes(rate: int, audio: np.ndarray) -> bytes:
    """float 배열을 16-bit PCM WAV 바이트로 만든다.

    16-bit 로 고정하는 이유: 모바일 오디오 스택이 기대하는 형식이고,
    float32 WAV 는 읽지 못하는 도구가 많다.
    """
    a = np.asarray(audio)
    if a.ndim == 1:
        channels = 1
    elif a.ndim == 2:
        channels = a.shape[1]
        a = a.reshape(-1)
    else:
        raise WavError("1차원 또는 2차원 배열만 받습니다")

    if np.issubdtype(a.dtype, np.integer):
        pcm = a.astype("<i2")
    else:
        pcm = (np.clip(a, -1.0, 1.0) * 32767.0).astype("<i2")
    raw = pcm.tobytes()

    block = channels * 2
    fmt = struct.pack("<HHIIHH", PCM, channels, int(rate),
                      int(rate) * block, block, 16)
    body = (b"fmt " + struct.pack("<I", len(fmt)) + fmt
            + b"data" + struct.pack("<I", len(raw)) + raw)
    if len(raw) & 1:
        body += b"\x00"
    return b"RIFF" + struct.pack("<I", 4 + len(body)) + b"WAVE" + body


def write(target: str | Path | io.BytesIO, rate: int, audio: np.ndarray) -> None:
    """경로 또는 버퍼에 16-bit PCM WAV 로 쓴다."""
    blob = to_bytes(rate, audio)
    if isinstance(target, (str, Path)):
        Path(target).write_bytes(blob)
    else:
        target.write(blob)
