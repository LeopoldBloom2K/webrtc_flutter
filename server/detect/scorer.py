"""청크 하나에 점수를 매기는 계층.

Scorer 는 교체 가능한 인터페이스다. 지금은 신호 특징 기반 SignalScorer 하나만
있고, 나중에 다른 방식(워터마크 검증 등)을 넣더라도 위층은 바뀌지 않는다.

!! 중요 !!
SignalScorer 의 THRESHOLDS 는 **아직 보정되지 않은 임시값**이다.
실제 한국어 통화 데이터로 진짜/합성 각각의 특징 분포를 재고,
고정 오탐율(예: 정상 통화 3분에 1%) 지점에서 다시 잡아야 한다.
지금 나오는 p_spoof 는 파이프라인이 도는지 확인하는 용도이지
탐지 성능을 뜻하지 않는다. 응답의 calibrated=false 가 이를 표시한다.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Protocol

import numpy as np

from . import features

CALIBRATION_PATH = Path(__file__).with_name("calibration.json")


def load_calibration() -> dict | None:
    """detect/calibrate.py 가 만든 보정 파일. 없으면 None."""
    try:
        return json.loads(CALIBRATION_PATH.read_text(encoding="utf-8"))
    except Exception:
        return None


class Scorer(Protocol):
    name: str
    calibrated: bool

    def score(self, audio: np.ndarray, sr: int) -> tuple[float, dict[str, float]]:
        """(p_spoof 0~1, 특징 dict) 를 돌려준다."""
        ...


def _ramp(value: float, lo: float, hi: float) -> float:
    """lo 이하면 0, hi 이상이면 1 로 가는 선형 사상."""
    if hi == lo:
        return 0.0
    return float(np.clip((value - lo) / (hi - lo), 0.0, 1.0))


class SignalScorer:
    """신호 특징을 합쳐 p_spoof 를 낸다. 학습 없음.

    각 항목은 '합성음일수록 커지는 방향'으로 정규화한 뒤 가중 평균한다.
    """

    name = "signal-v0"
    calibrated = False              # 데이터로 보정하기 전까지 False

    # (특징, 방향, lo, hi, 가중치)  — 전부 임시값
    THRESHOLDS = [
        # 자연 발화는 주기 변동이 있고 합성음은 과하게 규칙적이다 -> 낮을수록 의심
        ("jitter",      "low",  0.004, 0.020, 1.0),
        ("shimmer",     "low",  0.020, 0.090, 0.8),
        # 비주기 성분이 적으면 의심
        ("hnr_db",      "high", 5.0,  20.0,  0.8),
        # 고역이 부자연스럽게 잘리면 의심
        ("hf_ratio",    "low",  0.005, 0.060, 0.6),
    ]

    def __init__(self) -> None:
        cal = load_calibration()
        self.params: list[tuple] | None = None
        if cal and cal.get("scorer") == self.name and cal.get("feature_params"):
            # 보정된 방향·구간·가중치를 쓴다. 우연 수준이라 버려진 특징은 제외.
            self.params = [(k, v["direction"], v["lo"], v["hi"], v["weight"])
                           for k, v in cal["feature_params"].items()
                           if v.get("weight", 0) > 0]
            self.calibrated = bool(self.params)

    def _table(self) -> list[tuple]:
        return self.params if self.params else self.THRESHOLDS

    def score(self, audio: np.ndarray, sr: int) -> tuple[float, dict[str, float]]:
        f = features.extract(audio, sr)

        # 발화가 거의 없는 청크는 판단하지 않고 중립값을 돌려준다
        if f["voiced_ratio"] < 0.15 or f["rms"] < 1e-3:
            f["_skipped"] = 1.0
            return 0.5, f

        total = 0.0
        weight = 0.0
        for key, direction, lo, hi, w in self._table():
            r = _ramp(f.get(key, 0.0), lo, hi)
            sub = (1.0 - r) if direction == "low" else r
            total += sub * w
            weight += w
        f["_skipped"] = 0.0
        return float(np.clip(total / (weight + 1e-12), 0.0, 1.0)), f


# 보정 파일(detect/calibration.json)이 있으면 그 파라미터로 동작하고
# calibrated=True 가 된다. 없으면 THRESHOLDS 임시값 + calibrated=False.
DEFAULT: Scorer = SignalScorer()
