"""임계값 보정 — 라벨된 음성으로 운영 임계값을 계산한다.

왜 이분 탐색인가
  임계값 t 를 올리면 오경보율은 단조 감소한다. 단조 함수에서 목표값을 주는
  지점을 찾는 문제이므로 이분 탐색이 정확히 맞는다. 격자 탐색과 달리
  해상도를 O(log n) 으로 올릴 수 있고, 경계에서 튀지 않는다.

  세 군데에 쓴다
    1) 고정 오탐율 지점의 청크 임계값      threshold_for_far()
    2) EER (FAR = FRR 교차점)             eer()
    3) 통화 단위 오경보 목표를 만족하는
       상태 전이 임계값                    tune_states()

무엇을 기준으로 잡는가
  청크 단위 오탐율이 아니라 **통화 단위 오경보율**을 목표로 잡는다.
  사용자가 겪는 것은 "정상 통화 3분에 경고가 떴는가"이지 청크 하나가 아니다.
  같은 청크 임계값이라도 창 길이와 유지 조건에 따라 통화 단위 결과가 달라진다.

사용
  python3 -m detect.calibrate --bonafide data/real --spoof data/fake \\
                              --out detect/calibration.json
  각 디렉터리에 WAV 를 넣으면 청크로 잘라 점수를 모은 뒤 임계값을 계산한다.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path

import numpy as np

import wavio

from .scorer import DEFAULT, Scorer

TOL = 1e-4
MAX_ITER = 60


# ── 점수 수집 ────────────────────────────────────────────────────────────

def _read(path: Path) -> tuple[int, np.ndarray]:
    sr, audio = wavio.read(path)
    if audio.ndim > 1:
        audio = audio[:, 0]
    return sr, audio


def features_dir(directory: Path, chunk_s: float = 1.0) -> list[list[dict]]:
    """디렉터리의 WAV 를 청크로 잘라 특징을 뽑는다. 파일별로 묶어서 돌려준다."""
    from . import features as F
    out: list[list[dict]] = []
    for path in sorted(directory.rglob("*.wav")):
        try:
            sr, audio = _read(path)
        except Exception as e:
            print(f"  건너뜀 {path.name}: {e}", file=sys.stderr)
            continue
        n = int(sr * chunk_s)
        if n < 1 or len(audio) < n:
            continue
        rows = [F.extract(audio[i:i + n], sr)
                for i in range(0, len(audio) - n + 1, n)]
        if rows:
            out.append(rows)
    return out


def score_dir(directory: Path, scorer: Scorer = DEFAULT,
              chunk_s: float = 1.0) -> list[list[float]]:
    """디렉터리의 WAV 를 청크로 잘라 점수를 낸다.

    파일별 리스트로 돌려준다. 통화 단위 모의에서 같은 파일 안의 연속 구간을
    뽑아야 청크 간 상관이 보존되기 때문이다 (iid 로 섞으면 오경보율이
    실제보다 낙관적으로 나온다).
    """
    out: list[list[float]] = []
    files = sorted(p for p in directory.rglob("*.wav"))
    for path in files:
        try:
            sr, audio = _read(path)
        except Exception as e:
            print(f"  건너뜀 {path.name}: {e}", file=sys.stderr)
            continue
        n = int(sr * chunk_s)
        if n < 1 or len(audio) < n:
            continue
        scores = [scorer.score(audio[i:i + n], sr)[0]
                  for i in range(0, len(audio) - n + 1, n)]
        if scores:
            out.append(scores)
    return out


def flat(per_file: list[list[float]]) -> np.ndarray:
    return np.array([s for f in per_file for s in f], dtype=float)


# ── 특징 분석 ────────────────────────────────────────────────────────────

FEATURE_KEYS = ["jitter", "shimmer", "hnr_db", "hf_ratio", "flatness_hi", "slope"]


def auc(bona: np.ndarray, spoof: np.ndarray) -> float:
    """spoof 값이 bona 값보다 클 확률. 0.5 = 구분 불가, 0 또는 1 = 완전 분리."""
    if bona.size == 0 or spoof.size == 0:
        return 0.5
    gt = (spoof[:, None] > bona[None, :]).astype(float)
    eq = (spoof[:, None] == bona[None, :]).astype(float)
    return float(np.mean(gt + 0.5 * eq))


def analyze_features(bona_rows: list[dict], spoof_rows: list[dict],
                     min_sep: float = 0.15) -> dict:
    """각 특징의 방향·구간·가중치를 데이터에서 정한다.

    손으로 정한 방향이 틀리면 그 특징이 점수를 반대로 끌어내린다. 실제로
    초기 임시값에서 jitter 와 shimmer 의 방향이 반대였고, 그 둘이 잘 맞는
    특징(hf_ratio, slope)을 상쇄해 전체 EER 을 우연 수준으로 만들었다.

    방향  : spoof 쪽 중앙값이 크면 "high", 작으면 "low"
    구간  : 두 분포를 감싸는 백분위수 (10 / 90)
    가중치: |AUC-0.5| 에 비례. 우연 수준(min_sep 미만)이면 0 — 즉 버린다.
    """
    params = {}
    for key in FEATURE_KEYS:
        b = np.array([r.get(key, 0.0) for r in bona_rows], dtype=float)
        s = np.array([r.get(key, 0.0) for r in spoof_rows], dtype=float)
        a = auc(b, s)
        sep = abs(a - 0.5) * 2.0                       # 0 = 우연, 1 = 완전 분리
        direction = "high" if a >= 0.5 else "low"
        if direction == "high":
            lo, hi = float(np.percentile(b, 10)), float(np.percentile(s, 90))
        else:
            lo, hi = float(np.percentile(s, 10)), float(np.percentile(b, 90))
            direction = "low"
        if hi <= lo:
            lo, hi = float(min(lo, hi)), float(max(lo, hi) + 1e-9)
        weight = 0.0 if sep < min_sep else round(sep, 4)
        params[key] = {"direction": direction, "lo": round(lo, 6),
                       "hi": round(hi, 6), "auc": round(a, 4),
                       "separation": round(sep, 4), "weight": weight}
    return params


def score_with(params: dict, rows: list[dict]) -> np.ndarray:
    """analyze_features 가 만든 파라미터로 점수를 다시 계산한다."""
    out = []
    for f in rows:
        total = weight = 0.0
        for key, p in params.items():
            if p["weight"] <= 0.0:
                continue
            r = float(np.clip((f.get(key, 0.0) - p["lo"]) / (p["hi"] - p["lo"]),
                              0.0, 1.0))
            sub = r if p["direction"] == "high" else 1.0 - r
            total += sub * p["weight"]
            weight += p["weight"]
        out.append(total / weight if weight > 0 else 0.5)
    return np.array(out, dtype=float)


# ── 이분 탐색 ────────────────────────────────────────────────────────────

def _bisect(f, lo: float, hi: float, target: float) -> float:
    """f 가 [lo,hi] 에서 단조 감소한다고 보고 f(t)=target 인 t 를 찾는다."""
    if f(lo) <= target:
        return lo
    if f(hi) >= target:
        return hi
    for _ in range(MAX_ITER):
        mid = (lo + hi) / 2.0
        v = f(mid)
        if abs(v - target) < TOL or hi - lo < TOL:
            return mid
        if v > target:
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2.0


def far_at(spoof: np.ndarray, t: float) -> float:
    """위조를 진짜로 통과시킨 비율 (놓침)."""
    return float(np.mean(spoof < t)) if spoof.size else 0.0


def frr_at(bona: np.ndarray, t: float) -> float:
    """진짜를 위조로 오인한 비율 (오경보)."""
    return float(np.mean(bona >= t)) if bona.size else 0.0


def threshold_for_far(bona: np.ndarray, target_far: float) -> float:
    """정상 음성의 청크 오경보율이 target_far 가 되는 임계값. 이분 탐색."""
    return _bisect(lambda t: frr_at(bona, t), 0.0, 1.0, target_far)


def eer(bona: np.ndarray, spoof: np.ndarray) -> tuple[float, float]:
    """FAR = FRR 교차점. 차이가 단조라 이분 탐색으로 찾는다."""
    if bona.size == 0 or spoof.size == 0:
        return float("nan"), 0.5
    t = _bisect(lambda x: frr_at(bona, x) - far_at(spoof, x), 0.0, 1.0, 0.0)
    return (frr_at(bona, t) + far_at(spoof, t)) / 2.0, t


def bootstrap_eer_ci(bona: np.ndarray, spoof: np.ndarray,
                     n: int = 400, seed: int = 0) -> tuple[float, float]:
    """EER 의 95% 신뢰구간. 표본이 작으면 EER 차이는 의미가 없다."""
    if bona.size < 5 or spoof.size < 5:
        return float("nan"), float("nan")
    rng = np.random.default_rng(seed)
    vals = []
    for _ in range(n):
        b = rng.choice(bona, bona.size, replace=True)
        s = rng.choice(spoof, spoof.size, replace=True)
        vals.append(eer(b, s)[0])
    return float(np.percentile(vals, 2.5)), float(np.percentile(vals, 97.5))


# ── 통화 단위 오경보 ─────────────────────────────────────────────────────

def call_alarm_rate(per_file: list[list[float]], suspect_at: float,
                    detect_at: float, window: int, hold: int,
                    call_chunks: int, trials: int = 600,
                    seed: int = 0) -> float:
    """정상 통화에서 ai_suspected 이상이 한 번이라도 뜰 확률.

    같은 파일 안의 연속 구간을 뽑아 청크 간 상관을 보존한다. iid 로 섞으면
    오경보율이 실제보다 낙관적으로 나온다.
    """
    import importlib
    sess = importlib.import_module("session")
    rng = np.random.default_rng(seed)
    usable = [f for f in per_file if len(f) >= 2]
    if not usable:
        return 0.0
    alarms = 0
    for _ in range(trials):
        f = usable[rng.integers(len(usable))]
        if len(f) >= call_chunks:
            start = int(rng.integers(0, len(f) - call_chunks + 1))
            seq = f[start:start + call_chunks]
        else:                                   # 짧으면 이어 붙인다
            reps = -(-call_chunks // len(f))
            seq = (f * reps)[:call_chunks]
        tr = sess.Track(window=window, suspect_at=suspect_at,
                        detect_at=detect_at, hold_chunks=hold)
        fired = False
        for s in seq:
            st = tr.push(s)
            if st in (sess.AI_SUSPECTED, sess.AI_DETECTED):
                fired = True
                break
        alarms += fired
    return alarms / trials


def tune_states(bona_per_file: list[list[float]], window: int, hold: int,
                call_seconds: float, chunk_s: float,
                target_call_far: float) -> tuple[float, float]:
    """통화 단위 오경보 목표를 만족하는 suspect_at / detect_at 을 찾는다.

    임계값을 올리면 경보율이 단조 감소하므로 이분 탐색이 성립한다.
    detect_at 은 suspect_at 보다 엄격하게, 목표의 1/5 지점에서 잡는다.
    """
    call_chunks = max(1, int(round(call_seconds / chunk_s)))

    def rate(t: float) -> float:
        return call_alarm_rate(bona_per_file, t, 1.01, window, hold,
                                call_chunks, 600, 0)

    suspect = _bisect(rate, 0.0, 1.0, target_call_far)

    def rate_d(t: float) -> float:
        return call_alarm_rate(bona_per_file, suspect, t, window, hold,
                                call_chunks, 600, 1)

    detect = _bisect(rate_d, suspect, 1.0, target_call_far / 5.0)
    return round(suspect, 4), round(max(detect, suspect + 0.01), 4)


# ── 결과 ─────────────────────────────────────────────────────────────────

@dataclass
class Calibration:
    scorer: str
    created_at: str
    source: dict                      # 무슨 데이터로 잡았는지 — 반드시 기록
    chunk_seconds: float
    window: int
    hold_chunks: int
    suspect_at: float
    detect_at: float
    chunk_threshold_far1: float
    eer: float
    eer_ci95: list[float]
    call_alarm_rate: float
    feature_params: dict = field(default_factory=dict)
    notes: list[str] = field(default_factory=list)

    def save(self, path: Path) -> None:
        path.write_text(json.dumps(asdict(self), indent=2, ensure_ascii=False),
                        encoding="utf-8")


def calibrate(bona_dir: Path, spoof_dir: Path, chunk_s: float = 1.0,
              window: int = 5, hold: int = 3, call_seconds: float = 180.0,
              target_call_far: float = 0.01) -> Calibration:
    print(f"[1/5] 특징 추출  chunk={chunk_s}s")
    bona_files = features_dir(bona_dir, chunk_s)
    spoof_files = features_dir(spoof_dir, chunk_s)
    if not bona_files or not spoof_files:
        raise SystemExit("양쪽 모두 WAV 가 있어야 합니다")
    print(f"      bonafide {len(bona_files)}개 파일 / "
          f"{sum(len(f) for f in bona_files)} 청크")
    print(f"      spoof    {len(spoof_files)}개 파일 / "
          f"{sum(len(f) for f in spoof_files)} 청크")

    # 파일 단위로 나눈다. 청크 단위로 나누면 같은 파일이 양쪽에 걸쳐
    # 성능이 과대평가된다.
    def split(files):
        h = max(1, len(files) // 2)
        return files[:h], files[h:]

    bona_fit, bona_ev = split(bona_files)
    spoof_fit, spoof_ev = split(spoof_files)
    print(f"      fit {len(bona_fit)}+{len(spoof_fit)} 파일 / "
          f"eval {len(bona_ev)}+{len(spoof_ev)} 파일 (파일 단위 분할)")

    rows = lambda fs: [r for f in fs for r in f]

    print("[2/5] 특징별 방향·가중치 (fit 절반)")
    params = analyze_features(rows(bona_fit), rows(spoof_fit))
    print(f"      {'특징':<13}{'AUC':>7}{'방향':>7}{'가중치':>9}")
    for k, v in params.items():
        mark = "" if v["weight"] > 0 else "   <- 버림"
        print(f"      {k:<13}{v['auc']:7.3f}{v['direction']:>7}"
              f"{v['weight']:9.3f}{mark}")
    if all(v["weight"] <= 0 for v in params.values()):
        raise SystemExit("쓸 만한 특징이 없습니다. 특징을 바꿔야 합니다.")

    print("[3/5] EER (eval 절반, 이분 탐색)")
    b_ev = score_with(params, rows(bona_ev))
    s_ev = score_with(params, rows(spoof_ev))
    e, t_eer = eer(b_ev, s_ev)
    ci = bootstrap_eer_ci(b_ev, s_ev)
    print(f"      EER = {e * 100:.2f}%  (임계값 {t_eer:.4f})")
    print(f"      95% CI = [{ci[0] * 100:.2f}%, {ci[1] * 100:.2f}%]")

    print("[4/5] 청크 단위 오탐 1% 지점 (이분 탐색)")
    t_far1 = threshold_for_far(b_ev, 0.01)
    print(f"      t = {t_far1:.4f}  (이 지점 놓침률 {far_at(s_ev, t_far1) * 100:.1f}%)")

    print(f"[5/5] 통화 {call_seconds:.0f}초 오경보 {target_call_far * 100:.0f}% "
          f"목표 상태 임계값 (이분 탐색)")
    bona_ev_scores = [list(score_with(params, f)) for f in bona_ev]
    call_chunks = max(1, int(round(call_seconds / chunk_s)))
    shortest = min(len(f) for f in bona_ev_scores)
    sim_ok = shortest >= call_chunks and len(bona_ev_scores) >= 20
    suspect, detect = tune_states(bona_ev_scores, window, hold, call_seconds,
                                  chunk_s, target_call_far)
    # 서로 다른 시드로 반복해 추정의 흔들림까지 본다
    runs = [call_alarm_rate(bona_ev_scores, suspect, detect, window, hold,
                            call_chunks, 600, sd) for sd in (7, 11, 23, 41, 57)]
    achieved = float(np.mean(runs))
    spread = float(np.max(runs) - np.min(runs))
    print(f"      suspect_at={suspect}  detect_at={detect}")
    print(f"      실측 오경보 {achieved * 100:.2f}%  (시드별 편차 {spread * 100:.1f}%p)")
    if not sim_ok:
        print(f"      ! 통화 모의가 성립하지 않는다: 파일당 최단 {shortest}청크 "
              f"< 통화 {call_chunks}청크, 파일 {len(bona_ev_scores)}개")
        print(f"        짧은 파일을 반복해 채우므로 한 파일이 통화 전체를 지배한다.")

    notes = []
    if ci[1] - ci[0] > 0.10:
        notes.append("EER 신뢰구간이 넓다(>10%p). 데이터를 늘려야 한다.")
    if e > 0.30:
        notes.append("EER 30% 초과 — 이 특징 조합으로는 분리가 부족하다.")
    if not sim_ok:
        notes.append(
            f"통화 단위 오경보 추정을 신뢰할 수 없다. 파일이 통화 길이"
            f"({call_seconds:.0f}초)보다 짧거나(최단 {shortest * chunk_s:.0f}초) "
            f"파일 수가 부족하다(bonafide eval {len(bona_ev_scores)}개, 20개 이상 권장). "
            f"suspect_at/detect_at 은 임시값으로 보라.")
    elif achieved > target_call_far * 1.5:
        notes.append("목표 오경보율을 만족하지 못했다. 창을 늘리거나 특징을 바꿔야 한다.")
    if e < 0.02:
        notes.append(
            "EER 이 2% 미만이다. 데이터가 지나치게 쉽거나 두 집단이 특징 하나로 "
            "완전히 갈린다는 뜻이다. 실제 TTS 로 다시 재야 한다.")
    dropped = [k for k, v in params.items() if v["weight"] <= 0]
    if dropped:
        notes.append(f"우연 수준이라 버린 특징: {', '.join(dropped)}")

    return Calibration(
        scorer=DEFAULT.name,
        created_at=time.strftime("%Y-%m-%dT%H:%M:%S"),
        source={"bonafide": str(bona_dir), "spoof": str(spoof_dir),
                "bonafide_files": len(bona_files), "spoof_files": len(spoof_files),
                "fit_files": len(bona_fit) + len(spoof_fit),
                "eval_files": len(bona_ev) + len(spoof_ev)},
        chunk_seconds=chunk_s, window=window, hold_chunks=hold,
        suspect_at=suspect, detect_at=detect,
        chunk_threshold_far1=round(t_far1, 4),
        eer=round(float(e), 4), eer_ci95=[round(ci[0], 4), round(ci[1], 4)],
        call_alarm_rate=round(achieved, 4),
        feature_params=params, notes=notes)


def main() -> int:
    ap = argparse.ArgumentParser(description="탐지 임계값 보정")
    ap.add_argument("--bonafide", type=Path, required=True)
    ap.add_argument("--spoof", type=Path, required=True)
    ap.add_argument("--out", type=Path, default=Path("detect/calibration.json"))
    ap.add_argument("--chunk", type=float, default=1.0)
    ap.add_argument("--window", type=int, default=5)
    ap.add_argument("--hold", type=int, default=3)
    ap.add_argument("--call-seconds", type=float, default=180.0)
    ap.add_argument("--target-call-far", type=float, default=0.01)
    a = ap.parse_args()

    cal = calibrate(a.bonafide, a.spoof, a.chunk, a.window, a.hold,
                    a.call_seconds, a.target_call_far)
    cal.save(a.out)
    print(f"\n저장: {a.out}")
    for n in cal.notes:
        print(f"  ! {n}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
