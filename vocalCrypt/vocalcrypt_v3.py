"""
VocalCrypt v3 - 동적 최적화 버전

핵심 개선: auto_calibrate() 함수
  - 입력 오디오의 신호 크기, F0, 대역별 에너지를 분석
  - 목표 SNR을 유지하면서 각 공격의 strength를 자동 계산
  - 어떤 화자, 어떤 볼륨, 어떤 F0에도 일관된 방어 효과

원리:
  허용 노이즈 RMS = signal_RMS / 10^(target_snr/20)
  각 공격의 strength당 노이즈 RMS를 측정하여 역산
  SNR 예산을 공격 효과 가중치에 따라 배분

사용법:
  python3 vocalcrypt_v3.py input.wav output.wav --report
  python3 vocalcrypt_v3.py input.wav output.wav --target_snr 20 --report
  python3 vocalcrypt_v3.py input.wav output.wav --preset aggressive --report
"""

import numpy as np
import scipy.io.wavfile as wavfile
import scipy.signal as signal
from scipy.fft import rfft, irfft, rfftfreq
import argparse, os, sys

# ═══════════════════════════════════════════════
# 프리셋: target_snr만 다르게, strength는 자동 계산
# ═══════════════════════════════════════════════
PRESETS = {
    "safe":       {"target_snr": 26},
    "balanced":   {"target_snr": 22},
    "aggressive": {"target_snr": 18},
}

# ═══════════════════════════════════════════════
# F0 추정
# ═══════════════════════════════════════════════
def estimate_f0(audio, sr, f0_min=60, f0_max=400):
    n = min(len(audio), sr // 5)
    if n < 100: return 120.0
    frame = audio[:n] * np.hanning(n)
    corr = np.correlate(frame, frame, mode='full')[n-1:]
    lo = max(int(sr / f0_max), 1)
    hi = min(int(sr / f0_min), len(corr) - 1)
    if lo >= hi: return 120.0
    peak = np.argmax(corr[lo:hi]) + lo
    return float(np.clip(sr / peak if peak > 0 else 120, f0_min, f0_max))


# ═══════════════════════════════════════════════
# 공격 함수들
# ═══════════════════════════════════════════════
def adaptive_formant_attack(audio, sr, strength, f0=None):
    """F0~F3 전 대역 적응형 chirp 공격 (대역별 에너지 비례 강도)"""
    nyq = sr / 2.0
    result = audio.copy()
    t = np.arange(len(audio)) / sr
    bands = [(70, 300), (300, 900), (900, 2000), (2000, 3400)]

    energies = []
    for lo, hi in bands:
        hi_c = min(hi, nyq * 0.93)
        if lo >= hi_c:
            energies.append(1e-12); continue
        sos = signal.butter(6, [lo/nyq, hi_c/nyq], btype='band', output='sos')
        energies.append(np.sqrt(np.mean(signal.sosfilt(sos, audio)**2)) + 1e-12)

    total_e = sum(energies)
    for (lo, hi), band_e in zip(bands, energies):
        hi_c = min(hi, nyq * 0.93)
        if lo >= hi_c: continue
        try:
            sos = signal.butter(6, [lo/nyq, hi_c/nyq], btype='band', output='sos')
            ew = band_e / total_e
            adaptive_s = strength * (1.0 + 2.0 * ew)
            f_c = (lo + hi) / 2.0
            dev = (hi - lo) * 0.10
            chirp = signal.chirp(t, f0=f_c-dev, f1=f_c+dev, t1=t[-1])
            chirp = signal.sosfilt(sos, chirp)
            peak = np.max(np.abs(chirp))
            if peak < 1e-12: continue
            result += adaptive_s * band_e * chirp / peak
        except: pass
    return result


def harmonic_disruption(audio, sr, strength, f0=None):
    """배음(1~8배) 위치에 주파수 편이 + 위상 랜덤 신호 삽입"""
    if f0 is None: f0 = estimate_f0(audio, sr)
    t = np.arange(len(audio)) / sr
    result = audio.copy()
    rng = np.random.default_rng(2345)
    nyq = sr / 2.0
    weights = [1.0, 0.85, 0.70, 0.55, 0.40, 0.30, 0.20, 0.15]
    for k, w in enumerate(weights, start=1):
        f_h = f0 * k
        if f_h >= nyq * 0.9: break
        bw = max(f0 * 0.3, 20)
        lo = max(f_h - bw, 20); hi = min(f_h + bw, nyq * 0.93)
        if lo >= hi: continue
        sos = signal.butter(4, [lo/nyq, hi/nyq], btype='band', output='sos')
        harm_rms = np.sqrt(np.mean(signal.sosfilt(sos, audio)**2)) + 1e-12
        offset = f0 * rng.uniform(0.05, 0.15)
        phase = rng.uniform(0, 2 * np.pi)
        interferer = np.sin(2 * np.pi * (f_h + offset) * t + phase)
        mod = 0.6 + 0.4 * np.sin(2 * np.pi * 2.5 * t + rng.uniform(0, np.pi))
        result += strength * w * harm_rms * interferer * mod
    return result


def pitch_neighbor_interference(audio, sr, strength, f0=None):
    """배음 사이(0.5, 1.5... 배수)에 pseudo-tone 삽입"""
    if f0 is None: f0 = estimate_f0(audio, sr)
    t = np.arange(len(audio)) / sr
    result = audio.copy()
    rng = np.random.default_rng(5678)
    for k in [0.5, 1.5, 2.5, 3.5, 4.5, 5.5]:
        f_i = f0 * k
        if f_i > sr / 2 * 0.9: continue
        tone = np.sin(2 * np.pi * f_i * t + rng.uniform(0, 2 * np.pi))
        env = 0.5 + 0.5 * np.sin(2 * np.pi * 2.7 * t + rng.uniform(0, np.pi))
        result += strength * tone * env
    return result


def mel_bin_boundary_attack(audio, sr, strength, f0=None, n_mels=80):
    """TTS 멜 필터뱅크 경계 주파수에 에너지 집중"""
    nyq = sr / 2
    mel_min = 2595 * np.log10(1 + 20 / 700)
    mel_max = 2595 * np.log10(1 + nyq / 700)
    hz_bins = 700 * (10 ** (np.linspace(mel_min, mel_max, n_mels+2) / 2595) - 1)
    targets = hz_bins[(hz_bins >= 200) & (hz_bins <= 4000)]
    t = np.arange(len(audio)) / sr
    result = audio.copy()
    rng = np.random.default_rng(9012)
    for f_b in targets[::2]:
        if f_b >= nyq * 0.95: continue
        result += strength * np.sin(2 * np.pi * f_b * t + rng.uniform(0, 2 * np.pi))
    return result


def phase_randomization(audio, sr, strength, f0=None):
    """위상 랜덤화 (선택)"""
    N = len(audio)
    spec = rfft(audio)
    freqs = np.arange(len(spec)) * sr / N
    mask = (freqs >= 200) & (freqs <= 4000)
    rng = np.random.default_rng(3456)
    pn = rng.uniform(-np.pi * strength, np.pi * strength, np.sum(mask))
    spec[mask] = np.abs(spec[mask]) * np.exp(1j * (np.angle(spec[mask]) + pn))
    return irfft(spec, n=N)


# ═══════════════════════════════════════════════
# 동적 캘리브레이션 (핵심)
# ═══════════════════════════════════════════════

# 공격 함수 목록 및 가중치
# 가중치: 같은 노이즈 예산이라면 어느 공격에 더 많이 줄 것인가
# 포르만트와 배음이 화자 임베딩에 가장 직접적 영향 → 높은 가중치
ATTACK_REGISTRY = [
    ("formant",  adaptive_formant_attack,     3.0),  # 가중치 높음 (화자 정체성 핵심)
    ("harmonic", harmonic_disruption,         2.0),  # 배음 구조 직접 공격
    ("pitch",    pitch_neighbor_interference, 1.5),  # F0 간섭
    ("mel",      mel_bin_boundary_attack,     1.0),  # 멜빈 경계
]


def auto_calibrate(audio, sr, target_snr_db=22.0, use_phase=False, verbose=True):
    """
    입력 오디오를 분석하여 각 공격의 strength를 자동 계산

    원리:
      1. 신호 RMS로 허용 노이즈 예산 계산
      2. 각 공격 함수가 strength=0.01일 때 추가하는 노이즈 RMS 측정
      3. 가중치에 따라 예산 배분
      4. 역산으로 strength 결정

    Returns:
        dict: 각 공격의 strength 값
        float: 추정 F0
    """
    # 정규화된 신호 기준으로 측정
    input_peak = np.max(np.abs(audio))
    norm_gain = 0.9 / (input_peak + 1e-12)
    work = audio * norm_gain

    signal_rms = np.sqrt(np.mean(work**2))
    allowed_noise_rms = signal_rms / (10 ** (target_snr_db / 20.0))

    f0 = estimate_f0(work, sr)
    if verbose:
        print(f"  [캘리브레이션] 신호RMS={signal_rms:.4f}, "
              f"허용노이즈RMS={allowed_noise_rms:.5f} (목표SNR={target_snr_db}dB), F0={f0:.1f}Hz")

    # 각 공격의 strength당 노이즈 RMS 측정 (probe_strength=0.01)
    probe_s = 0.01
    noise_per_unit = {}
    for name, fn, _ in ATTACK_REGISTRY:
        try:
            out = fn(work, sr, strength=probe_s, f0=f0)
            diff = out - work
            npu = np.sqrt(np.mean(diff**2)) / probe_s
            noise_per_unit[name] = max(npu, 1e-10)
        except:
            noise_per_unit[name] = 1e-10

    if use_phase:
        try:
            out = phase_randomization(work, sr, strength=probe_s)
            diff = out - work
            noise_per_unit["phase"] = np.sqrt(np.mean(diff**2)) / probe_s
        except:
            noise_per_unit["phase"] = 1e-10

    # 가중치 기반 예산 배분
    # RMS 합산: sqrt(sum(w_i * budget)^2) = allowed → budget = allowed / sqrt(sum(w_i^2))
    registry = list(ATTACK_REGISTRY)
    if use_phase:
        registry.append(("phase", phase_randomization, 0.5))

    total_weight_sq = sum(w**2 for _, _, w in registry)
    base_budget = allowed_noise_rms / np.sqrt(total_weight_sq)

    strengths = {}
    for name, fn, weight in registry:
        npu = noise_per_unit.get(name, 1e-10)
        budget = base_budget * weight
        strengths[name] = budget / npu

    if verbose:
        print(f"  [캘리브레이션] 자동 strength: " +
              ", ".join(f"{k}={v:.4f}" for k, v in strengths.items()))

    return strengths, f0


# ═══════════════════════════════════════════════
# 메인 파이프라인
# ═══════════════════════════════════════════════
def vocalcrypt_v3_protect(
    audio, sr,
    target_snr=22.0,
    use_phase=False,
    # 수동 오버라이드 (None이면 자동 계산)
    formant_strength=None,
    harmonic_strength=None,
    pitch_strength=None,
    mel_strength=None,
    phase_strength=None,
    verbose=True,
):
    """
    VocalCrypt v3 동적 최적화 파이프라인

    Args:
        audio       : float64 오디오 [-1, 1]
        sr          : 샘플레이트
        target_snr  : 목표 SNR (dB) - 이 값을 유지하면서 방어 최대화
        use_phase   : 위상 랜덤화 사용 여부
        *_strength  : 수동 오버라이드 (None이면 target_snr 기반 자동 계산)
    """
    if verbose:
        print(f"[VocalCrypt v3] SR={sr}Hz | {len(audio)/sr:.2f}초 | 목표SNR={target_snr}dB")

    input_peak = np.max(np.abs(audio))
    if input_peak < 1e-8:
        if verbose: print("  [경고] 신호 없음")
        return audio.copy()

    rms = np.sqrt(np.mean(audio**2))
    if verbose:
        print(f"  입력: peak={input_peak:.4f}, RMS={rms:.5f}"
              + (" [정규화 적용]" if input_peak < 0.3 else ""))

    norm_gain = 0.9 / input_peak
    work = audio * norm_gain

    # 수동 지정 여부 확인
    manual = any(x is not None for x in
                 [formant_strength, harmonic_strength, pitch_strength, mel_strength])

    if manual:
        # 수동 모드: 지정된 값 사용, 없으면 캘리브레이션으로 보완
        strengths, f0 = auto_calibrate(work, sr, target_snr, use_phase, verbose=False)
        f0 = estimate_f0(work, sr)
        if formant_strength  is not None: strengths['formant']  = formant_strength
        if harmonic_strength is not None: strengths['harmonic'] = harmonic_strength
        if pitch_strength    is not None: strengths['pitch']    = pitch_strength
        if mel_strength      is not None: strengths['mel']      = mel_strength
        if phase_strength    is not None: strengths['phase']    = phase_strength
        if verbose: print(f"  [수동 오버라이드] F0={f0:.1f}Hz")
    else:
        # 자동 모드: target_snr 기반으로 전부 계산
        strengths, f0 = auto_calibrate(work, sr, target_snr, use_phase, verbose)

    acts = [f"{k}({v:.4f})" for k, v in strengths.items()]
    if verbose:
        print(f"  F0={f0:.1f}Hz | {' + '.join(acts)}")

    # 각 공격 적용
    attack_map = {
        "formant":  (adaptive_formant_attack,     {"f0": f0}),
        "harmonic": (harmonic_disruption,         {"f0": f0}),
        "pitch":    (pitch_neighbor_interference, {"f0": f0}),
        "mel":      (mel_bin_boundary_attack,     {}),
        "phase":    (phase_randomization,         {}),
    }

    for i, (name, s) in enumerate(strengths.items(), start=1):
        fn, kw = attack_map[name]
        try:
            work = fn(work, sr, strength=s, **kw)
            if verbose: print(f"  [{i}] {name} 완료")
        except Exception as e:
            if verbose: print(f"  [{i}] {name} 오류: {e}")

    # 원래 볼륨 복원
    work = work / norm_gain
    mv = np.max(np.abs(work))
    if mv > 1.0: work = work / mv * 0.99
    return work


# ═══════════════════════════════════════════════
# 입출력 / 품질 평가
# ═══════════════════════════════════════════════
def load_wav(path):
    sr, d = wavfile.read(path)
    if d.ndim > 1: d = d[:,0]
    m = {np.int16: 32768., np.int32: 2147483648., np.float32: 1.}
    return sr, d.astype(np.float64) / m.get(d.dtype.type, 1.)

def save_wav(path, audio, sr):
    wavfile.write(path, sr, np.clip(audio, -1, 1).astype(np.float32))
    print(f"[저장] {path}")

def compute_snr(orig, prot):
    n = min(len(orig), len(prot))
    diff = prot[:n] - orig[:n]
    sp = np.mean(orig[:n]**2)
    np_ = np.mean(diff**2)
    return 10 * np.log10(sp / (np_ + 1e-15)) if np_ > 1e-15 else float('inf')

def quality_report(orig, prot, sr):
    n = min(len(orig), len(prot))
    orig, prot, diff = orig[:n], prot[:n], prot[:n] - orig[:n]
    nyq = sr / 2

    snr = compute_snr(orig, prot)
    print(f"\n[품질 리포트]")
    print(f"  SNR: {snr:.2f} dB  {'✅' if snr >= 20 else '⚠️'}")
    print(f"  변화량 RMS: {np.sqrt(np.mean(diff**2)):.5f}")
    print(f"\n  대역별 공격 효율 (밴드패스 RMS 기준):")

    key_o, key_d = 0.0, 0.0
    for name, lo, hi in [("F0  70~300Hz ", 70, 300), ("F1 300~900Hz", 300, 900),
                          ("F2 900~2kHz  ", 900, 2000), ("F3 2k~3.4kHz", 2000, 3400)]:
        hi_c = min(hi, nyq * 0.93)
        if lo >= hi_c: continue
        sos = signal.butter(6, [lo/nyq, hi_c/nyq], btype='band', output='sos')
        ro = np.sqrt(np.mean(signal.sosfilt(sos, orig)**2))
        rd = np.sqrt(np.mean(signal.sosfilt(sos, diff)**2))
        r = rd / (ro + 1e-20)
        bar = "█" * int(min(r * 100, 25))
        print(f"    {name}: {r:.4f} {'✅' if r > 0.03 else '❌'} {bar}")
        if lo >= 200:
            key_o += ro**2; key_d += rd**2

    key_r = np.sqrt(key_d) / (np.sqrt(key_o) + 1e-20)
    print(f"\n  핵심대역(200~3.4kHz) 종합: {key_r:.4f} "
          f"{'✅ 충분' if key_r >= 0.05 else f'⚠️ {0.05-key_r:.4f} 부족'}")


# ═══════════════════════════════════════════════
# CLI
# ═══════════════════════════════════════════════
def main():
    p = argparse.ArgumentParser(
        description="VocalCrypt v3: 동적 최적화 보이스 클로닝 방어",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "프리셋 (target_snr만 다름, strength는 자동 계산):\n"
            "  safe       SNR ~26dB | 음질 우선\n"
            "  balanced   SNR ~22dB | 균형 [기본값]\n"
            "  aggressive SNR ~18dB | 방어 최대화\n\n"
            "예시:\n"
            "  # 자동 최적화 (권장)\n"
            "  python3 vocalcrypt_v3.py in.wav out.wav --report\n\n"
            "  # 목표 SNR 직접 지정\n"
            "  python3 vocalcrypt_v3.py in.wav out.wav --target_snr 20 --report\n\n"
            "  # 특정 strength만 수동 오버라이드\n"
            "  python3 vocalcrypt_v3.py in.wav out.wav --formant_str 0.06 --report\n"
        )
    )
    p.add_argument("input"); p.add_argument("output")
    p.add_argument("--preset",       default="balanced", choices=list(PRESETS.keys()))
    p.add_argument("--target_snr",   type=float, default=None,
                   help="목표 SNR dB (지정 시 프리셋 무시)")
    p.add_argument("--formant_str",  type=float, default=None)
    p.add_argument("--harmonic_str", type=float, default=None)
    p.add_argument("--pitch_str",    type=float, default=None)
    p.add_argument("--mel_str",      type=float, default=None)
    p.add_argument("--with_phase",   action="store_true")
    p.add_argument("--report",       action="store_true")
    a = p.parse_args()

    if not os.path.exists(a.input):
        print(f"[오류] 파일 없음: {a.input}"); sys.exit(1)

    sr, audio = load_wav(a.input)
    print(f"[로드] {a.input} | {sr}Hz | {len(audio)/sr:.2f}초")

    target_snr = a.target_snr if a.target_snr is not None \
                 else PRESETS[a.preset]["target_snr"]
    print(f"[프리셋] {a.preset} | 목표SNR={target_snr}dB")

    prot = vocalcrypt_v3_protect(
        audio, sr,
        target_snr=target_snr,
        use_phase=a.with_phase,
        formant_strength=a.formant_str,
        harmonic_strength=a.harmonic_str,
        pitch_strength=a.pitch_str,
        mel_strength=a.mel_str,
    )

    if a.report:
        quality_report(audio, prot, sr)

    save_wav(a.output, prot, sr)
    print("✅ 완료!")

if __name__ == "__main__":
    main()