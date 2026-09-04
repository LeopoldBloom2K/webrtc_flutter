"""
VocalCrypt 방어 효과 평가 스크립트

평가 지표:
  1. SVA  (Speaker Verification Accuracy) - WeSpeaker x-vector
  2. EER  (Equal Error Rate)              - SVA 기반
  3. SECS (Speaker Encoder Cosine Similarity) - Resemblyzer
  4. DNSMOS (음질 평가, no-reference MOS) - DNSMOS P.835
  5. PESQ / STOI (음질 참조 지표)

설치 필요:
  pip install torch torchaudio resemblyzer speechbrain pesq pystoi

사용법:
  # 기본 (원본 vs 노이즈 처리된 음성)
  python evaluate_defense.py --orig daon_speak.wav --noisy v3_noise.wav

  # Qwen3 TTS로 클로닝한 결과까지 포함
  python evaluate_defense.py \
      --orig    daon_speak.wav \
      --noisy   v3_noise.wav \
      --clone_orig  clone_from_orig.wav \
      --clone_noisy clone_from_noisy.wav
"""

import numpy as np
import argparse, os, sys
import scipy.io.wavfile as wavfile
import scipy.signal as signal

# ═══════════════════════════════════════════════
# 오디오 로드 유틸
# ═══════════════════════════════════════════════
def load_wav(path, target_sr=None):
    sr, d = wavfile.read(path)
    if d.ndim > 1: d = d[:,0]
    m = {np.int16:32768., np.int32:2147483648., np.float32:1.}
    audio = d.astype(np.float64) / m.get(d.dtype.type, 1.)
    if target_sr and sr != target_sr:
        # 리샘플링
        num = int(len(audio) * target_sr / sr)
        audio = signal.resample(audio, num)
        sr = target_sr
    return sr, audio.astype(np.float32)


# ═══════════════════════════════════════════════
# 1. SECS: Speaker Encoder Cosine Similarity
#    Resemblyzer 기반 (GE2E speaker embedding)
# ═══════════════════════════════════════════════
def compute_secs(audio1, audio2, sr):
    """
    두 오디오의 화자 임베딩 코사인 유사도
    1.0 = 동일 화자, 0.0 = 무관
    방어 효과: 낮을수록 클로닝된 음성이 원본과 다름
    """
    from resemblyzer import VoiceEncoder, preprocess_wav
    import numpy as np

    encoder = VoiceEncoder()
    wav1 = preprocess_wav(audio1, source_sr=sr)
    wav2 = preprocess_wav(audio2, source_sr=sr)
    emb1 = encoder.embed_utterance(wav1)
    emb2 = encoder.embed_utterance(wav2)
    cos_sim = np.dot(emb1, emb2) / (np.linalg.norm(emb1) * np.linalg.norm(emb2))
    return float(cos_sim)


# ═══════════════════════════════════════════════
# 2. SVA: Speaker Verification Accuracy
#    SpeechBrain ECAPA-TDNN 기반
# ═══════════════════════════════════════════════
def compute_sva(audio_ref, audio_test, sr, threshold=0.25):
    """
    화자 검증 유사도 점수 (0~1)
    threshold 이상이면 동일 화자로 판정
    방어 효과: 낮을수록 화자 검증 실패
    """
    from speechbrain.pretrained import SpeakerRecognition
    import torch, tempfile

    model = SpeakerRecognition.from_hparams(
        source="speechbrain/spkrec-ecapa-voxceleb",
        savedir="pretrained_models/ecapa"
    )
    # 임시 파일로 저장 후 비교
    with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as f1, \
         tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as f2:
        wavfile.write(f1.name, sr, (audio_ref * 32767).astype(np.int16))
        wavfile.write(f2.name, sr, (audio_test * 32767).astype(np.int16))
        score, pred = model.verify_files(f1.name, f2.name)
        os.unlink(f1.name); os.unlink(f2.name)

    return float(score), bool(pred)


# ═══════════════════════════════════════════════
# 3. PESQ: Perceptual Evaluation of Speech Quality
#    참고: 16kHz 또는 8kHz만 지원
# ═══════════════════════════════════════════════
def compute_pesq(ref_audio, deg_audio, sr):
    """
    PESQ 점수 (-0.5 ~ 4.5, 높을수록 음질 좋음)
    방어 처리 후에도 4.0+ 유지가 목표
    """
    from pesq import pesq

    target_sr = 16000 if sr > 8000 else 8000
    if sr != target_sr:
        ref = signal.resample(ref_audio, int(len(ref_audio)*target_sr/sr))
        deg = signal.resample(deg_audio, int(len(deg_audio)*target_sr/sr))
    else:
        ref, deg = ref_audio, deg_audio

    mode = 'wb' if target_sr == 16000 else 'nb'
    min_len = min(len(ref), len(deg))
    score = pesq(target_sr, ref[:min_len].astype(np.float32),
                 deg[:min_len].astype(np.float32), mode)
    return float(score)


# ═══════════════════════════════════════════════
# 4. STOI: Short-Time Objective Intelligibility
# ═══════════════════════════════════════════════
def compute_stoi(ref_audio, deg_audio, sr):
    """
    STOI 점수 (0~1, 높을수록 명료도 높음)
    방어 처리 후에도 0.85+ 유지가 목표
    """
    from pystoi import stoi
    min_len = min(len(ref_audio), len(deg_audio))
    score = stoi(ref_audio[:min_len], deg_audio[:min_len], sr, extended=False)
    return float(score)


# ═══════════════════════════════════════════════
# 5. SNR / 스펙트럼 거리 (외부 의존성 없음)
# ═══════════════════════════════════════════════
def compute_snr(orig, processed):
    n = min(len(orig), len(processed))
    diff = processed[:n] - orig[:n]
    sp = np.mean(orig[:n]**2)
    np_ = np.mean(diff**2)
    return 10 * np.log10(sp / (np_ + 1e-15)) if np_ > 1e-15 else float('inf')


def compute_spectral_distance(audio1, audio2, sr):
    """
    Mel-Cepstral Distortion (MCD) - 화자 유사도 근사 지표
    외부 의존성 없이 계산
    낮을수록 두 음성이 비슷함
    방어 후 clone MCD가 높을수록 방어 효과 있음
    """
    from scipy.fft import rfft, rfftfreq
    n = min(len(audio1), len(audio2), sr * 3)  # 최대 3초
    a1, a2 = audio1[:n], audio2[:n]

    # 80개 멜 필터뱅크 에너지 계산
    n_mels = 80; n_fft = 1024; hop = 256
    n_frames = (n - n_fft) // hop
    if n_frames <= 0:
        return float('nan')

    def mel_filterbank_energy(audio):
        nyq = sr / 2
        mel_min = 2595 * np.log10(1 + 20 / 700)
        mel_max = 2595 * np.log10(1 + nyq / 700)
        hz_bins = 700 * (10**(np.linspace(mel_min, mel_max, n_mels+2)/2595) - 1)
        energies = []
        for i in range(n_frames):
            frame = audio[i*hop:i*hop+n_fft] * np.hanning(n_fft)
            spec = np.abs(rfft(frame))**2
            freqs = rfftfreq(n_fft, 1/sr)
            frame_e = []
            for j in range(n_mels):
                lo, hi = hz_bins[j], hz_bins[j+2]
                mask = (freqs >= lo) & (freqs < hi)
                frame_e.append(np.sum(spec[mask]) + 1e-10)
            energies.append(np.log(frame_e))
        return np.array(energies)  # (frames, n_mels)

    mel1 = mel_filterbank_energy(a1)
    mel2 = mel_filterbank_energy(a2)
    # MCD: log spectral 차이의 평균
    diff = mel1 - mel2
    mcd = np.sqrt(np.mean(diff**2))
    return float(mcd)


# ═══════════════════════════════════════════════
# 메인 평가 파이프라인
# ═══════════════════════════════════════════════
def evaluate(orig_path, noisy_path,
             clone_orig_path=None, clone_noisy_path=None,
             use_resemblyzer=True, use_speechbrain=True,
             use_pesq=True, use_stoi=True):

    print("=" * 60)
    print("VocalCrypt 방어 효과 평가")
    print("=" * 60)

    # 파일 로드
    sr_o, orig  = load_wav(orig_path)
    sr_n, noisy = load_wav(noisy_path)
    print(f"\n원본:     {orig_path} | {sr_o}Hz | {len(orig)/sr_o:.2f}초")
    print(f"노이즈 처리: {noisy_path} | {sr_n}Hz | {len(noisy)/sr_n:.2f}초")

    results = {}

    # ── 1. 음질 평가 (원본 vs 노이즈 처리) ──────
    print("\n[ 음질 평가: 원본 vs 노이즈 처리본 ]")

    snr_val = compute_snr(orig.astype(np.float64), noisy.astype(np.float64))
    results['SNR'] = snr_val
    print(f"  SNR:  {snr_val:.2f} dB  (목표: 20dB+)")

    if use_pesq:
        try:
            pesq_score = compute_pesq(orig, noisy, sr_o)
            results['PESQ'] = pesq_score
            print(f"  PESQ: {pesq_score:.3f}  (목표: 3.5+, 범위 -0.5~4.5)")
        except ImportError:
            print("  PESQ: 'pip install pesq' 필요")

    if use_stoi:
        try:
            stoi_score = compute_stoi(orig, noisy, sr_o)
            results['STOI'] = stoi_score
            print(f"  STOI: {stoi_score:.4f}  (목표: 0.85+, 범위 0~1)")
        except ImportError:
            print("  STOI: 'pip install pystoi' 필요")

    # ── 2. 화자 유사도 (원본 vs 노이즈 처리) ────
    print("\n[ 화자 유사도: 원본 vs 노이즈 처리본 ]")
    print("  (낮아야 함 → 클로닝 모델이 원본 화자를 학습 못함)")

    mcd_noisy = compute_spectral_distance(orig, noisy, sr_o)
    results['MCD_noisy'] = mcd_noisy
    print(f"  MCD (Mel-Cepstral Distortion): {mcd_noisy:.4f}  (높을수록 다름)")

    if use_resemblyzer:
        try:
            secs_noisy = compute_secs(orig, noisy, sr_o)
            results['SECS_noisy'] = secs_noisy
            print(f"  SECS (화자 임베딩 유사도): {secs_noisy:.4f}  (낮을수록 방어 효과)")
        except ImportError:
            print("  SECS: 'pip install resemblyzer' 필요")

    if use_speechbrain:
        try:
            score, pred = compute_sva(orig, noisy, sr_o)
            results['SVA_noisy'] = score
            results['SVA_noisy_pred'] = pred
            print(f"  SVA 점수: {score:.4f}, 동일화자 판정: {pred}")
        except ImportError:
            print("  SVA: 'pip install speechbrain' 필요")

    # ── 3. 클로닝 결과 비교 ─────────────────────
    if clone_orig_path and clone_noisy_path:
        sr_co, clone_orig  = load_wav(clone_orig_path)
        sr_cn, clone_noisy = load_wav(clone_noisy_path)
        print(f"\n[ 클로닝 결과 비교 ]")
        print(f"  클론(원본 기반):  {clone_orig_path}")
        print(f"  클론(노이즈 기반): {clone_noisy_path}")

        # 원본 vs 클론(원본) - 기준선
        mcd_clone_orig = compute_spectral_distance(orig, clone_orig, sr_o)
        results['MCD_clone_orig'] = mcd_clone_orig

        # 원본 vs 클론(노이즈) - 방어 후
        mcd_clone_noisy = compute_spectral_distance(orig, clone_noisy, sr_o)
        results['MCD_clone_noisy'] = mcd_clone_noisy

        improvement = mcd_clone_noisy / (mcd_clone_orig + 1e-10)
        print(f"\n  MCD (원본→클론):    {mcd_clone_orig:.4f}  ← 기준선")
        print(f"  MCD (원본→노이즈클론): {mcd_clone_noisy:.4f}  ← 방어 후")
        print(f"  MCD 배율: {improvement:.2f}x  {'✅ 방어 효과 있음' if improvement > 1.2 else '⚠️ 효과 미미'}")

        if use_resemblyzer:
            try:
                secs_co = compute_secs(orig, clone_orig,  sr_o)
                secs_cn = compute_secs(orig, clone_noisy, sr_o)
                results['SECS_clone_orig']  = secs_co
                results['SECS_clone_noisy'] = secs_cn
                print(f"\n  SECS 클론(원본):    {secs_co:.4f}")
                print(f"  SECS 클론(노이즈):  {secs_cn:.4f}")
                print(f"  SECS 감소: {secs_co-secs_cn:.4f}  {'✅' if secs_co-secs_cn > 0.05 else '⚠️'}")
            except ImportError:
                pass

        if use_speechbrain:
            try:
                s_co, p_co = compute_sva(orig, clone_orig,  sr_o)
                s_cn, p_cn = compute_sva(orig, clone_noisy, sr_o)
                results['SVA_clone_orig']  = s_co
                results['SVA_clone_noisy'] = s_cn
                print(f"\n  SVA 클론(원본):    {s_co:.4f}, 판정={p_co}")
                print(f"  SVA 클론(노이즈):  {s_cn:.4f}, 판정={p_cn}")
                eer_drop = s_co - s_cn
                print(f"  SVA 점수 하락: {eer_drop:.4f}  {'✅ 방어 성공' if eer_drop > 0.05 else '⚠️'}")
            except ImportError:
                pass

    # ── 4. 요약 ─────────────────────────────────
    print("\n" + "=" * 60)
    print("[ 평가 요약 ]")
    for k, v in results.items():
        if isinstance(v, float):
            print(f"  {k}: {v:.4f}")
        else:
            print(f"  {k}: {v}")

    return results


# ═══════════════════════════════════════════════
# EER 계산 유틸리티
# (SVA 점수 분포로부터 Equal Error Rate 계산)
# ═══════════════════════════════════════════════
def compute_eer(genuine_scores, impostor_scores):
    """
    EER (Equal Error Rate) 계산
    genuine_scores:  동일 화자 쌍의 유사도 점수
    impostor_scores: 다른 화자 쌍의 유사도 점수
    낮을수록 화자 검증 시스템 성능 좋음
    방어 후 EER이 높아지면 → 클로닝 된 음성이 원본으로 인식 안됨
    """
    thresholds = np.linspace(
        min(min(genuine_scores), min(impostor_scores)),
        max(max(genuine_scores), max(impostor_scores)),
        1000
    )
    min_diff = float('inf')
    eer = 0.0
    for t in thresholds:
        far = np.mean(np.array(impostor_scores) >= t)   # False Accept Rate
        frr = np.mean(np.array(genuine_scores) < t)     # False Reject Rate
        diff = abs(far - frr)
        if diff < min_diff:
            min_diff = diff
            eer = (far + frr) / 2
    return eer


# ═══════════════════════════════════════════════
# CLI
# ═══════════════════════════════════════════════
def main():
    p = argparse.ArgumentParser(
        description="VocalCrypt 방어 효과 정량 평가",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "사용 예시:\n"
            "  # 기본 (음질 + 화자 유사도만)\n"
            "  python evaluate_defense.py \\\n"
            "      --orig daon_speak.wav --noisy v3_noise.wav\n\n"
            "  # 클로닝 결과까지 포함 (완전한 방어 효과 평가)\n"
            "  python evaluate_defense.py \\\n"
            "      --orig          daon_speak.wav \\\n"
            "      --noisy         v3_noise.wav \\\n"
            "      --clone_orig    clone_from_orig.wav \\\n"
            "      --clone_noisy   clone_from_noisy.wav\n\n"
            "  # resemblyzer / speechbrain 없이 기본 지표만\n"
            "  python evaluate_defense.py \\\n"
            "      --orig daon_speak.wav --noisy v3_noise.wav \\\n"
            "      --no_resemblyzer --no_speechbrain\n"
        )
    )
    p.add_argument("--orig",          required=True, help="원본 음성")
    p.add_argument("--noisy",         required=True, help="VocalCrypt 처리된 음성")
    p.add_argument("--clone_orig",    default=None,  help="원본으로 클로닝한 결과")
    p.add_argument("--clone_noisy",   default=None,  help="노이즈 처리본으로 클로닝한 결과")
    p.add_argument("--no_resemblyzer",action="store_true")
    p.add_argument("--no_speechbrain",action="store_true")
    p.add_argument("--no_pesq",       action="store_true")
    p.add_argument("--no_stoi",       action="store_true")
    a = p.parse_args()

    for path in [a.orig, a.noisy]:
        if not os.path.exists(path):
            print(f"[오류] 파일 없음: {path}"); sys.exit(1)

    evaluate(
        orig_path=a.orig,
        noisy_path=a.noisy,
        clone_orig_path=a.clone_orig,
        clone_noisy_path=a.clone_noisy,
        use_resemblyzer=not a.no_resemblyzer,
        use_speechbrain=not a.no_speechbrain,
        use_pesq=not a.no_pesq,
        use_stoi=not a.no_stoi,
    )

if __name__ == "__main__":
    main()
