"""합성음 판별에 쓰는 신호 특징 — 학습 없이 계산으로만 구한다.

자연 발화는 성대 진동이 주기마다 미세하게 흔들리고(jitter/shimmer),
호흡·마찰에서 오는 비주기 성분이 섞이며, 고역이 완만하게 감쇠한다.
합성음은 이 미세 변동이 과도하게 규칙적이거나 고역이 부자연스럽게 잘린다.

주의: 여기서 뽑는 값은 '특징'일 뿐 판정이 아니다. 어떤 값이 어느 쪽을
가리키는지는 실제 한국어 통화 데이터로 분포를 재야 정해진다.
"""
from __future__ import annotations

import numpy as np
from scipy import signal as sig

EPS = 1e-12


def _frames(x: np.ndarray, n: int, hop: int) -> np.ndarray:
    if len(x) < n:
        return np.empty((0, n))
    count = 1 + (len(x) - n) // hop
    idx = np.arange(n)[None, :] + hop * np.arange(count)[:, None]
    return x[idx]


def _refine_peak(c: np.ndarray, p: int) -> float:
    """자기상관 최대점 주변을 포물선으로 보간해 소수점 lag 을 구한다.

    정수 lag 만 쓰면 F0 해상도가 145Hz 에서 약 0.9% 라, 자연 발화의
    jitter(0.5~2%)가 양자화 잡음에 묻힌다. 보간이 없으면 jitter 특징 자체가
    의미를 잃는다.
    """
    if p <= 0 or p >= len(c) - 1:
        return float(p)
    a, b, d = float(c[p - 1]), float(c[p]), float(c[p + 1])
    denom = a - 2.0 * b + d
    if abs(denom) < EPS:
        return float(p)
    delta = 0.5 * (a - d) / denom
    return float(p) + float(np.clip(delta, -0.5, 0.5))


def f0_track(x: np.ndarray, sr: int, fmin: float = 60.0, fmax: float = 400.0,
             frame_ms: float = 40.0, hop_ms: float = 10.0) -> np.ndarray:
    """프레임별 F0. 무성 구간은 NaN. 포물선 보간으로 소수점 해상도를 얻는다."""
    n = int(sr * frame_ms / 1000.0)
    hop = int(sr * hop_ms / 1000.0)
    fr = _frames(x, n, hop)
    if fr.size == 0:
        return np.array([])
    win = np.hanning(n)
    lo, hi = max(int(sr / fmax), 1), min(int(sr / fmin), n - 1)
    out = np.full(len(fr), np.nan)
    if lo >= hi:
        return out
    for i, f in enumerate(fr):
        f = (f - f.mean()) * win
        e = np.sqrt(np.mean(f ** 2))
        if e < 1e-4:
            continue
        c = np.correlate(f, f, mode="full")[n - 1:]
        c0 = c[0] + EPS
        peak = int(np.argmax(c[lo:hi])) + lo
        if c[peak] / c0 < 0.30:          # 주기성이 약하면 무성으로 본다
            continue
        lag = _refine_peak(c, peak)
        if lag > 0:
            out[i] = sr / lag
    return out


def jitter_shimmer(x: np.ndarray, sr: int) -> tuple[float, float, float]:
    """(jitter, shimmer, 유성 비율).

    jitter  = 주기의 상대 변동률, shimmer = 진폭의 상대 변동률.
    자연 발화는 보통 jitter 0.5~2% 범위, 합성음은 더 낮은 경향이 보고된다.
    """
    f0 = f0_track(x, sr)
    if f0.size == 0:
        return 0.0, 0.0, 0.0
    voiced = ~np.isnan(f0)
    ratio = float(voiced.mean())
    v = f0[voiced]
    if len(v) < 3:
        return 0.0, 0.0, ratio
    periods = 1.0 / v
    jitter = float(np.mean(np.abs(np.diff(periods))) / (np.mean(periods) + EPS))

    n = int(sr * 0.04)
    hop = int(sr * 0.01)
    fr = _frames(x, n, hop)
    amp = np.sqrt(np.mean(fr ** 2, axis=1)) if fr.size else np.array([])
    amp = amp[: len(f0)][voiced[: len(amp)]] if amp.size else amp
    shimmer = (float(np.mean(np.abs(np.diff(amp))) / (np.mean(amp) + EPS))
               if len(amp) >= 3 else 0.0)
    return jitter, shimmer, ratio


def hnr(x: np.ndarray, sr: int) -> float:
    """조화 대 잡음 비(dB). 합성음은 비주기 성분이 적어 높게 나오는 경향."""
    n = int(sr * 0.04)
    hop = int(sr * 0.02)
    fr = _frames(x, n, hop)
    if fr.size == 0:
        return 0.0
    lo, hi = max(int(sr / 400), 1), min(int(sr / 60), n - 1)
    vals = []
    for f in fr:
        f = f - f.mean()
        e = np.sqrt(np.mean(f ** 2))
        if e < 1e-4 or lo >= hi:
            continue
        c = np.correlate(f, f, mode="full")[n - 1:]
        r = float(np.max(c[lo:hi]) / (c[0] + EPS))
        r = min(max(r, 1e-4), 0.999)
        vals.append(10.0 * np.log10(r / (1.0 - r)))
    return float(np.mean(vals)) if vals else 0.0


def spectral(x: np.ndarray, sr: int) -> dict[str, float]:
    """평탄도·고역 비율·스펙트럼 기울기."""
    nper = min(1024, len(x))
    if nper < 64:
        return {"flatness_hi": 0.0, "hf_ratio": 0.0, "slope": 0.0}
    f, p = sig.welch(x, sr, nperseg=nper)
    p = p + EPS
    hi = (f >= 4000) & (f <= min(8000, sr / 2))
    flat_hi = (float(np.exp(np.mean(np.log(p[hi]))) / np.mean(p[hi]))
               if hi.sum() > 2 else 0.0)
    total = float(np.sum(p))
    hf_ratio = float(np.sum(p[hi]) / total) if hi.sum() else 0.0
    band = (f >= 200) & (f <= min(7000, sr / 2))
    if band.sum() > 4:
        slope = float(np.polyfit(np.log10(f[band] + EPS), 10 * np.log10(p[band]), 1)[0])
    else:
        slope = 0.0
    return {"flatness_hi": flat_hi, "hf_ratio": hf_ratio, "slope": slope}


def extract(x: np.ndarray, sr: int) -> dict[str, float]:
    """청크 하나에서 특징 전부."""
    if x.size == 0:
        return {"jitter": 0.0, "shimmer": 0.0, "voiced_ratio": 0.0, "hnr_db": 0.0,
                "flatness_hi": 0.0, "hf_ratio": 0.0, "slope": 0.0, "rms": 0.0}
    j, s, vr = jitter_shimmer(x, sr)
    out = {"jitter": j, "shimmer": s, "voiced_ratio": vr, "hnr_db": hnr(x, sr),
           "rms": float(np.sqrt(np.mean(x ** 2)))}
    out.update(spectral(x, sr))
    return out
