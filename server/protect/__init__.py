"""VocalCrypt — 송신 음성에 적대적 노이즈를 주입한다.

알고리즘은 A파트 원본 `vocalCrypt/vocalcrypt_v3.py` 를 그대로 불러 쓴다.
서버 쪽에 복사본을 두지 않으므로, A파트가 원본을 고치면 서버를 재시작하는 것만으로
통화 경로에 반영된다. 서버에서 쓰는 진입점만 여기서 다시 노출한다.
"""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

# 레포 루트의 vocalCrypt/ — server/ 와 같은 레벨에 있어야 한다.
SOURCE = Path(__file__).resolve().parents[2] / "vocalCrypt" / "vocalcrypt_v3.py"
if not SOURCE.is_file():
    raise ImportError(
        f"VocalCrypt 원본을 찾을 수 없습니다: {SOURCE}\n"
        "server/ 와 같은 레벨에 vocalCrypt/vocalcrypt_v3.py 가 있어야 합니다.")

_spec = importlib.util.spec_from_file_location("protect.vocalcrypt_v3", SOURCE)
vocalcrypt_v3 = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = vocalcrypt_v3          # import protect.vocalcrypt_v3 도 그대로 동작
_spec.loader.exec_module(vocalcrypt_v3)

PRESETS = vocalcrypt_v3.PRESETS
estimate_f0 = vocalcrypt_v3.estimate_f0
load_wav = vocalcrypt_v3.load_wav
save_wav = vocalcrypt_v3.save_wav
compute_snr = vocalcrypt_v3.compute_snr
vocalcrypt_v3_protect = vocalcrypt_v3.vocalcrypt_v3_protect

__all__ = [
    "SOURCE",
    "PRESETS",
    "estimate_f0",
    "load_wav",
    "save_wav",
    "compute_snr",
    "vocalcrypt_v3_protect",
]
