"""
VocalCrypt FastAPI 서버
Flutter 앱에서 HTTP로 음성 파일을 보내면 노이즈 처리 후 반환

실행:
  pip install fastapi uvicorn python-multipart numpy scipy
  python vocalcrypt_server.py

엔드포인트:
  POST /protect   - WAV 파일 → VocalCrypt 처리 → WAV 반환
  GET  /health    - 서버 상태 확인
"""

import io
import tempfile
import os
import numpy as np
import scipy.io.wavfile as wavfile
import scipy.signal as signal
from scipy.fft import rfft, irfft, rfftfreq

from fastapi import FastAPI, File, UploadFile, Form
from fastapi.responses import Response
import uvicorn

app = FastAPI(title="VocalCrypt Server")

# ── VocalCrypt v3 핵심 함수 (vocalcrypt_v3.py에서 복사) ──────────────────

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

def adaptive_formant_attack(audio, sr, strength, f0=None):
    nyq = sr / 2.0; result = audio.copy()
    t = np.arange(len(audio)) / sr
    bands = [(70,300),(300,900),(900,2000),(2000,3400)]
    energies = []
    for lo, hi in bands:
        hi_c = min(hi, nyq*0.93)
        if lo >= hi_c: energies.append(1e-12); continue
        sos = signal.butter(6,[lo/nyq,hi_c/nyq],btype='band',output='sos')
        energies.append(np.sqrt(np.mean(signal.sosfilt(sos,audio)**2))+1e-12)
    total_e = sum(energies)
    for (lo,hi),band_e in zip(bands,energies):
        hi_c = min(hi,nyq*0.93)
        if lo >= hi_c: continue
        try:
            sos = signal.butter(6,[lo/nyq,hi_c/nyq],btype='band',output='sos')
            ew = band_e/total_e; ads = strength*(1.0+2.0*ew)
            f_c=(lo+hi)/2; dev=(hi-lo)*0.10
            chirp = signal.chirp(t,f0=f_c-dev,f1=f_c+dev,t1=t[-1])
            chirp = signal.sosfilt(sos,chirp)
            peak = np.max(np.abs(chirp))
            if peak < 1e-12: continue
            result += ads*band_e*chirp/peak
        except: pass
    return result

def harmonic_disruption(audio, sr, strength, f0=None):
    if f0 is None: f0 = estimate_f0(audio, sr)
    t = np.arange(len(audio))/sr; result = audio.copy()
    rng = np.random.default_rng(2345); nyq = sr/2.0
    weights = [1.0,0.85,0.70,0.55,0.40,0.30,0.20,0.15]
    for k,w in enumerate(weights,start=1):
        f_h = f0*k
        if f_h >= nyq*0.9: break
        bw = max(f0*0.3,20); lo=max(f_h-bw,20); hi=min(f_h+bw,nyq*0.93)
        if lo >= hi: continue
        sos = signal.butter(4,[lo/nyq,hi/nyq],btype='band',output='sos')
        harm_rms = np.sqrt(np.mean(signal.sosfilt(sos,audio)**2))+1e-12
        offset = f0*rng.uniform(0.05,0.15); phase = rng.uniform(0,2*np.pi)
        interferer = np.sin(2*np.pi*(f_h+offset)*t+phase)
        mod = 0.6+0.4*np.sin(2*np.pi*2.5*t+rng.uniform(0,np.pi))
        result += strength*w*harm_rms*interferer*mod
    return result

def pitch_neighbor_interference(audio, sr, strength, f0=None):
    if f0 is None: f0 = estimate_f0(audio, sr)
    t = np.arange(len(audio))/sr; result = audio.copy()
    rng = np.random.default_rng(5678)
    for k in [0.5,1.5,2.5,3.5,4.5,5.5]:
        f_i = f0*k
        if f_i > sr/2*0.9: continue
        tone = np.sin(2*np.pi*f_i*t+rng.uniform(0,2*np.pi))
        env = 0.5+0.5*np.sin(2*np.pi*2.7*t+rng.uniform(0,np.pi))
        result += strength*tone*env
    return result

def mel_bin_boundary_attack(audio, sr, strength, f0=None, n_mels=80):
    nyq = sr/2
    mel_min = 2595*np.log10(1+20/700); mel_max = 2595*np.log10(1+nyq/700)
    hz_bins = 700*(10**(np.linspace(mel_min,mel_max,n_mels+2)/2595)-1)
    targets = hz_bins[(hz_bins>=200)&(hz_bins<=4000)]
    t = np.arange(len(audio))/sr; result = audio.copy()
    rng = np.random.default_rng(9012)
    for f_b in targets[::2]:
        if f_b >= nyq*0.95: continue
        result += strength*np.sin(2*np.pi*f_b*t+rng.uniform(0,2*np.pi))
    return result

ATTACK_REGISTRY = [
    ("formant",  adaptive_formant_attack,     3.0),
    ("harmonic", harmonic_disruption,         2.0),
    ("pitch",    pitch_neighbor_interference, 1.5),
    ("mel",      mel_bin_boundary_attack,     1.0),
]

def auto_calibrate(audio, sr, target_snr_db=22.0):
    input_peak = np.max(np.abs(audio))
    norm_gain = 0.9/(input_peak+1e-12)
    work = audio*norm_gain
    signal_rms = np.sqrt(np.mean(work**2))
    allowed_noise_rms = signal_rms/(10**(target_snr_db/20.0))
    f0 = estimate_f0(work, sr)
    probe_s = 0.01; noise_per_unit = {}
    for name,fn,_ in ATTACK_REGISTRY:
        try:
            out = fn(work,sr,strength=probe_s,f0=f0)
            npu = np.sqrt(np.mean((out-work)**2))/probe_s
            noise_per_unit[name] = max(npu,1e-10)
        except: noise_per_unit[name] = 1e-10
    total_wq = sum(w**2 for _,_,w in ATTACK_REGISTRY)
    base_budget = allowed_noise_rms/np.sqrt(total_wq)
    strengths = {}
    for name,_,weight in ATTACK_REGISTRY:
        strengths[name] = base_budget*weight/noise_per_unit.get(name,1e-10)
    return strengths, f0

def vocalcrypt_protect(audio, sr, target_snr=22.0):
    input_peak = np.max(np.abs(audio))
    if input_peak < 1e-8: return audio.copy()
    norm_gain = 0.9/input_peak
    work = audio*norm_gain
    strengths, f0 = auto_calibrate(work, sr, target_snr)
    attack_map = {
        "formant":  (adaptive_formant_attack,     {"f0": f0}),
        "harmonic": (harmonic_disruption,         {"f0": f0}),
        "pitch":    (pitch_neighbor_interference, {"f0": f0}),
        "mel":      (mel_bin_boundary_attack,     {}),
    }
    for name,s in strengths.items():
        fn,kw = attack_map[name]
        try: work = fn(work,sr,strength=s,**kw)
        except: pass
    work = work/norm_gain
    mv = np.max(np.abs(work))
    if mv > 1.0: work = work/mv*0.99
    return work

# ── FastAPI 엔드포인트 ────────────────────────────────────────────────────

@app.get("/health")
async def health():
    return {"status": "ok", "version": "v3"}

@app.post("/protect")
async def protect_audio(
    file: UploadFile = File(...),
    target_snr: float = Form(default=22.0),
):
    """
    WAV 파일을 받아 VocalCrypt 처리 후 반환

    Args:
        file:       WAV 파일 (multipart/form-data)
        target_snr: 목표 SNR (기본 22.0 dB)

    Returns:
        처리된 WAV 파일 (audio/wav)
    """
    # 업로드된 파일 읽기
    contents = await file.read()

    # WAV 파싱
    buf = io.BytesIO(contents)
    sr, data = wavfile.read(buf)
    if data.ndim > 1: data = data[:,0]
    m = {np.int16:32768., np.int32:2147483648., np.float32:1.}
    audio = data.astype(np.float64)/m.get(data.dtype.type,1.)

    # VocalCrypt 처리
    protected = vocalcrypt_protect(audio, sr, target_snr=target_snr)

    # WAV로 직렬화
    out_buf = io.BytesIO()
    wavfile.write(out_buf, sr, np.clip(protected,-1,1).astype(np.float32))
    out_buf.seek(0)

    return Response(
        content=out_buf.read(),
        media_type="audio/wav",
        headers={"Content-Disposition": "attachment; filename=protected.wav"}
    )

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8765, log_level="info")