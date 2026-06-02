# WebRTC 오디오 패킷 실시간 모니터링 스크립트
# 두 에뮬레이터에서 마이크 권한 자동 부여 후 [Audio Check] 로그를 실시간 출력합니다.
# 실행: .\scripts\monitor_audio.ps1

$package = "com.example.webrtc_flutter"

# ── 1. 연결된 에뮬레이터 목록 확인 ────────────────────────────────────────────
Write-Host ""
Write-Host "=== WebRTC 오디오 패킷 모니터 ===" -ForegroundColor Cyan
Write-Host ""

$adbOutput = & adb devices 2>&1
$deviceIds = $adbOutput |
    Where-Object { $_ -match "emulator.*device$" } |
    ForEach-Object { ($_ -split "\s+")[0].Trim() } |
    Where-Object { $_ -ne "" }

if ($deviceIds.Count -eq 0) {
    Write-Host "[ERROR] 연결된 Android 에뮬레이터가 없습니다." -ForegroundColor Red
    Write-Host "  → AVD Manager에서 에뮬레이터를 실행한 뒤 다시 시도하세요."
    exit 1
}

Write-Host "감지된 에뮬레이터 ($($deviceIds.Count)개): $($deviceIds -join ', ')" -ForegroundColor Cyan

# ── 2. 마이크 권한 자동 부여 ──────────────────────────────────────────────────
Write-Host ""
Write-Host "--- 마이크 권한 자동 부여 ---" -ForegroundColor Yellow

foreach ($id in $deviceIds) {
    Write-Host "[$id] 권한 부여 중..." -NoNewline
    $r1 = & adb -s $id shell pm grant $package android.permission.RECORD_AUDIO 2>&1
    $r2 = & adb -s $id shell pm grant $package android.permission.MODIFY_AUDIO_SETTINGS 2>&1
    if ($LASTEXITCODE -eq 0 -or $r1 -notmatch "Exception") {
        Write-Host " 완료 (RECORD_AUDIO, MODIFY_AUDIO_SETTINGS)" -ForegroundColor Green
    } else {
        Write-Host " [주의] 앱이 설치되지 않았거나 이미 거부됨. 앱 빌드 후 다시 실행하세요." -ForegroundColor Red
    }
}

# ── 3. 실시간 [Audio Check] 로그 스트리밍 ────────────────────────────────────
Write-Host ""
Write-Host "--- [Audio Check] 실시간 모니터링 시작 (Ctrl+C로 종료) ---" -ForegroundColor Green
Write-Host "출력 형식:"
Write-Host "  [Audio Check] 🎤 Mic Input Level: (수치) | 📤 Sent Packets: (증가량)"
Write-Host "  [Audio Check] 🔊 Speaker Stream: ACTIVE/SILENT | 📥 Received Packets: (증가량) | Bytes: (증가량)"
Write-Host ""
Write-Host "색상 기준: " -NoNewline
Write-Host "초록=정상 흐름  " -ForegroundColor Green -NoNewline
Write-Host "빨강=패킷 없음/STALL  " -ForegroundColor Red -NoNewline
Write-Host "노랑=부분 흐름" -ForegroundColor Yellow
Write-Host "─" * 70
Write-Host ""

# 에뮬레이터별 백그라운드 logcat 잡 시작
$jobs = foreach ($id in $deviceIds) {
    Start-Job -Name "logcat_$id" -ScriptBlock {
        param($devId)
        # flutter:V *:S — flutter 태그 Verbose 수준으로 필터링
        # dev.log(name:'AudioCheck') 출력은 flutter 태그로 logcat에 기록됨
        & adb -s $devId logcat flutter:V "*:S" 2>&1 | ForEach-Object {
            if ($_ -match '\[Audio Check\]') {
                "[$devId] $_"
            }
        }
    } -ArgumentList $id
}

try {
    while ($true) {
        foreach ($job in $jobs) {
            $lines = Receive-Job -Job $job
            foreach ($line in $lines) {
                if (-not $line) { continue }

                # 색상 결정
                if ($line -match 'STALL|⚠️') {
                    Write-Host $line -ForegroundColor Red
                } elseif ($line -match 'ACTIVE' -and $line -match '\+[1-9]') {
                    Write-Host $line -ForegroundColor Green
                } elseif ($line -match 'ACTIVE' -or $line -match '\+[1-9]') {
                    Write-Host $line -ForegroundColor Yellow
                } elseif ($line -match 'SILENT|\+0') {
                    Write-Host $line -ForegroundColor Red
                } else {
                    Write-Host $line
                }
            }
        }
        Start-Sleep -Milliseconds 200
    }
}
finally {
    $jobs | Stop-Job
    $jobs | Remove-Job -Force
    Write-Host ""
    Write-Host "모니터링 종료." -ForegroundColor Yellow
}
