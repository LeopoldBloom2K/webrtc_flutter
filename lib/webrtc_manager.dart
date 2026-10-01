// lib/webrtc_manager.dart  (VocalCrypt 통합 버전)
//
// 변경 사항:
//   - VocalCryptService 주입 지원
//   - initialize()에서 마이크 스트림 획득 후 VocalCrypt 처리 상태 기록
//   - protectAndRecord(): 레퍼런스 오디오를 보호하는 공개 메서드 추가
//   - vocalCryptEnabled 플래그로 ON/OFF 가능

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:record/record.dart'; // pub: record (마이크 녹음)
import 'package:path_provider/path_provider.dart';

import 'vocalcrypt_service.dart';

class AudioStats {
  final double micLevel;
  final int sentDelta;
  final int receivedDelta;
  final int bytesReceivedDelta;
  final bool speakerActive;
  final bool isStalled;

  const AudioStats({
    required this.micLevel,
    required this.sentDelta,
    required this.receivedDelta,
    required this.bytesReceivedDelta,
    required this.speakerActive,
    required this.isStalled,
  });
}

class AudioStreamStatus {
  final bool localActive;
  final bool remoteActive;
  const AudioStreamStatus({
    required this.localActive,
    required this.remoteActive,
  });
}

// VocalCrypt 처리 상태
enum VocalCryptStatus { idle, recording, processing, done, error }

abstract class AbstractWebRTCManager {
  Function(RTCIceCandidate candidate)? onIceCandidate;
  Function(RTCSessionDescription offer)? onOfferCreated;
  Function(RTCSessionDescription answer)? onAnswerCreated;
  Function(RTCPeerConnectionState state)? onConnectionStateChange;
  Function(RTCIceConnectionState state)? onIceConnectionStateChange;
  Function(AudioStats stats)? onAudioStatsUpdate;
  // VocalCrypt 상태 콜백
  Function(VocalCryptStatus status, String message)? onVocalCryptStatus;

  Future<void> initialize();
  Future<void> createOffer();
  Future<void> createAnswer();
  Future<void> setRemoteDescription(String sdp, String type);
  Future<void> addIceCandidate(
    String candidate,
    String? sdpMid,
    int? sdpMLineIndex,
  );
  Future<void> close();

  AudioStreamStatus getAudioStatus() =>
      const AudioStreamStatus(localActive: false, remoteActive: false);

  /// 통화 전 레퍼런스 오디오 녹음 + VocalCrypt 보호
  /// [durationSeconds]: 녹음 시간 (기본 3초)
  /// [sampleRate]: 녹음 샘플레이트. 주입되는 노이즈가 4kHz 이하에 몰려 있어
  ///   16kHz 로 충분하다. 48kHz 는 비교용으로만 쓴다.
  Future<VocalCryptResult?> captureAndProtect({
    int durationSeconds = 3,
    int sampleRate = 16000,
  }) async => null;

  /// 같은 조건에서 여러 샘플레이트를 차례로 녹음·보호해 비교한다.
  Future<Map<int, VocalCryptResult?>> compareSampleRates({
    int durationSeconds = 3,
    List<int> sampleRates = const [16000, 48000],
  }) async => {};
}

class WebRTCManager extends AbstractWebRTCManager {
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  bool _isClosed = false;
  Timer? _statsTimer;
  int _prevPacketsSent = 0;
  int _prevPacketsReceived = 0;
  int _prevBytesReceived = 0;
  int _stallCount = 0;

  // ── VocalCrypt 추가 필드 ─────────────────────────────────────
  final VocalCryptService? vocalCryptService;
  bool vocalCryptEnabled;
  VocalCryptStatus _vcStatus = VocalCryptStatus.idle;
  Uint8List? _lastProtectedAudio; // 가장 최근 처리된 보호 오디오

  @override
  Function(RTCIceCandidate candidate)? onIceCandidate;
  @override
  Function(RTCSessionDescription offer)? onOfferCreated;
  @override
  Function(RTCSessionDescription answer)? onAnswerCreated;
  @override
  Function(RTCPeerConnectionState state)? onConnectionStateChange;
  @override
  Function(RTCIceConnectionState state)? onIceConnectionStateChange;
  @override
  Function(AudioStats stats)? onAudioStatsUpdate;
  @override
  Function(VocalCryptStatus status, String message)? onVocalCryptStatus;

  WebRTCManager({this.vocalCryptService, this.vocalCryptEnabled = true});

  static const _iceServers = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
    ],
    'iceCandidatePoolSize': 10,
  };

  @override
  Future<void> initialize() async {
    _isClosed = false;
    _peerConnection = await createPeerConnection(_iceServers);

    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': false,
    });

    for (final track in _localStream!.getAudioTracks()) {
      await _peerConnection!.addTrack(track, _localStream!);
    }

    _peerConnection!.onIceCandidate = (RTCIceCandidate? candidate) {
      if (_isClosed || candidate == null || candidate.candidate == null) return;
      onIceCandidate?.call(candidate);
    };

    _peerConnection!.onConnectionState = (RTCPeerConnectionState state) {
      if (_isClosed) return;
      debugPrint('[WebRTC] connectionState → $state');
      onConnectionStateChange?.call(state);
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _startStatsMonitor();
      }
    };

    _peerConnection!.onIceConnectionState = (RTCIceConnectionState state) {
      if (_isClosed) return;
      debugPrint('[WebRTC] iceConnectionState → $state');
      onIceConnectionStateChange?.call(state);
    };

    _peerConnection!.onTrack = (RTCTrackEvent event) {
      if (_isClosed || event.streams.isEmpty) return;
      _remoteStream = event.streams.first;
    };
  }

  // ── VocalCrypt 핵심 메서드 ────────────────────────────────────
  //
  // 사용 시나리오:
  //   통화 연결 전에 UI에서 "음성 보호 시작" 버튼 → captureAndProtect() 호출
  //   보호된 오디오를 저장해두고 클로닝 방어에 활용
  //   (실시간 스트림 처리는 현재 flutter_webrtc API 한계로 지원 불가)

  @override
  Future<VocalCryptResult?> captureAndProtect({
    int durationSeconds = 3,
    int sampleRate = 16000,
  }) async {
    if (!vocalCryptEnabled || vocalCryptService == null) return null;
    if (_isClosed) return null;

    // 서버 생존 확인
    final serverAlive = await vocalCryptService!.isServerAlive();
    if (!serverAlive) {
      _notifyVocalCrypt(VocalCryptStatus.error, 'VocalCrypt 서버에 연결할 수 없습니다');
      return null;
    }

    // 마이크 녹음
    _notifyVocalCrypt(
      VocalCryptStatus.recording,
      '음성 샘플 녹음 중... ($durationSeconds초 @ ${sampleRate}Hz)',
    );
    final wavBytes = await _recordMicrophone(durationSeconds, sampleRate);
    if (wavBytes == null) {
      _notifyVocalCrypt(VocalCryptStatus.error, '녹음 실패');
      return null;
    }
    _logInputLevel(wavBytes, sampleRate);

    // VocalCrypt 서버에 전송
    _notifyVocalCrypt(VocalCryptStatus.processing, 'VocalCrypt 처리 중...');
    final result = await vocalCryptService!.protect(wavBytes);

    if (result.success && result.protectedAudio != null) {
      _lastProtectedAudio = result.protectedAudio;
      _notifyVocalCrypt(
        VocalCryptStatus.done,
        '보호 완료 (${result.processingTimeMs?.toStringAsFixed(0)}ms)',
      );
      debugPrint('[VocalCrypt] 처리 완료: ${result.processingTimeMs}ms');
    } else {
      _notifyVocalCrypt(
        VocalCryptStatus.error,
        result.errorMessage ?? '알 수 없는 오류',
      );
    }
    return result;
  }

  @override
  Future<Map<int, VocalCryptResult?>> compareSampleRates({
    int durationSeconds = 3,
    List<int> sampleRates = const [16000, 48000],
  }) async {
    final out = <int, VocalCryptResult?>{};
    for (final sr in sampleRates) {
      final r = await captureAndProtect(
        durationSeconds: durationSeconds,
        sampleRate: sr,
      );
      out[sr] = r;
      debugPrint(
        '[VocalCrypt/비교] ${sr}Hz  '
        '왕복 ${r?.processingTimeMs?.toStringAsFixed(0) ?? '-'}ms  '
        '서버 ${r?.serverProcessingMs?.toStringAsFixed(0) ?? '-'}ms  '
        '실측SNR ${r?.serverSnrDb?.toStringAsFixed(1) ?? '-'}dB  '
        '입력 ${r?.serverInputRmsDbfs?.toStringAsFixed(1) ?? '-'}/'
        '${r?.serverInputPeakDbfs?.toStringAsFixed(1) ?? '-'}dBFS  '
        '${r?.protectedAudio?.length ?? 0}B  '
        '${r?.success == true ? 'OK' : (r?.errorMessage ?? '실패')}',
      );
    }
    return out;
  }

  void _notifyVocalCrypt(VocalCryptStatus status, String message) {
    _vcStatus = status;
    debugPrint('[VocalCrypt] $status: $message');
    onVocalCryptStatus?.call(status, message);
  }

  Future<Uint8List?> _recordMicrophone(int seconds, int sampleRate) async {
    try {
      final recorder = AudioRecorder();
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/vc_sample_${DateTime.now().millisecondsSinceEpoch}.wav';

      if (!await recorder.hasPermission()) return null;

      await recorder.start(
        RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: sampleRate,
          numChannels: 1,
        ),
        path: path,
      );
      await Future.delayed(Duration(seconds: seconds));
      await recorder.stop();

      final file = File(path);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      await file.delete(); // 임시 파일 정리
      return bytes;
    } catch (e) {
      debugPrint('[VocalCrypt] 녹음 오류: $e');
      return null;
    }
  }

  // 녹음된 WAV 의 절대 레벨을 앱에서 직접 잰다.
  //
  // 서버도 같은 값을 X-Input-Rms-Dbfs / X-Input-Peak-Dbfs 로 돌려주지만,
  // 마이크가 실제로 소리를 잡았는지는 이 프로젝트에서 가장 먼저 확인해야 하는
  // 사실이라 서버 재시작 여부에 의존하지 않도록 입력 지점에서도 남긴다.
  // SNR 은 신호 대비 상대값이어서 무음이 들어와도 목표치를 맞추므로, 무음인지
  // 아닌지는 이 절대값으로만 가려진다.
  void _logInputLevel(Uint8List wav, int sampleRate) {
    // record 의 wav 인코더는 44바이트 표준 헤더를 쓴다(실측). 뒤는 PCM16 LE 모노.
    const headerBytes = 44;
    if (wav.length <= headerBytes + 1) {
      debugPrint('[VocalCrypt/입력] WAV 가 너무 짧다 (${wav.length}B)');
      return;
    }
    // asInt16List 는 2바이트 정렬을 요구해서 실패할 수 있다. ByteData 는 아니다.
    final bd = ByteData.sublistView(wav, headerBytes);
    final n = bd.lengthInBytes ~/ 2;
    var sumSq = 0.0;
    var peak = 0;
    for (var i = 0; i < n; i++) {
      final s = bd.getInt16(i * 2, Endian.little);
      final v = s / 32768.0;
      sumSq += v * v;
      final a = s.abs();
      if (a > peak) peak = a;
    }
    String dbfs(double x) =>
        x > 0 ? (20.0 * math.log(x) / math.ln10).toStringAsFixed(1) : '-inf';
    debugPrint(
      '[VocalCrypt/입력] ${sampleRate}Hz  '
      '${(n / sampleRate).toStringAsFixed(2)}s  '
      'RMS ${dbfs(math.sqrt(sumSq / n))} / peak ${dbfs(peak / 32768.0)} dBFS'
      '${peak == 0 ? '  ← 완전 무음. 마이크가 전혀 잡히지 않았다' : ''}',
    );
  }

  // 보호된 오디오 바이트 반환 (외부에서 파일로 저장하거나 전송 시 사용)
  Uint8List? get lastProtectedAudio => _lastProtectedAudio;
  VocalCryptStatus get vocalCryptStatus => _vcStatus;

  // ── 기존 WebRTC 메서드 (변경 없음) ──────────────────────────
  @override
  Future<void> createOffer() async {
    if (_isClosed || _peerConnection == null) return;
    final offer = await _peerConnection!.createOffer({
      'mandatory': {'OfferToReceiveAudio': true, 'OfferToReceiveVideo': false},
    });
    if (_isClosed) return;
    await _peerConnection!.setLocalDescription(offer);
    if (_isClosed) return;
    onOfferCreated?.call(offer);
  }

  @override
  Future<void> createAnswer() async {
    if (_isClosed || _peerConnection == null) return;
    final answer = await _peerConnection!.createAnswer({
      'mandatory': {'OfferToReceiveAudio': true, 'OfferToReceiveVideo': false},
    });
    if (_isClosed) return;
    await _peerConnection!.setLocalDescription(answer);
    if (_isClosed) return;
    onAnswerCreated?.call(answer);
  }

  @override
  Future<void> setRemoteDescription(String sdp, String type) async {
    if (_isClosed || _peerConnection == null) return;
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(sdp, type),
    );
  }

  @override
  Future<void> addIceCandidate(
    String candidate,
    String? sdpMid,
    int? sdpMLineIndex,
  ) async {
    if (_isClosed || _peerConnection == null) return;
    await _peerConnection!.addCandidate(
      RTCIceCandidate(candidate, sdpMid, sdpMLineIndex),
    );
  }

  @override
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    _statsTimer?.cancel();
    _statsTimer = null;
    await _peerConnection?.close();
    _peerConnection?.dispose();
    _peerConnection = null;
    if (_localStream != null) {
      for (final track in _localStream!.getTracks()) {
        await track.stop();
      }
      await _localStream!.dispose();
      _localStream = null;
    }
    _remoteStream = null;
  }

  void _startStatsMonitor() {
    _statsTimer?.cancel();
    _prevPacketsSent = 0;
    _prevPacketsReceived = 0;
    _prevBytesReceived = 0;
    _stallCount = 0;
    _statsTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _checkAudioStats(),
    );
  }

  Future<void> _checkAudioStats() async {
    if (_isClosed || _peerConnection == null) return;
    try {
      final stats = await _peerConnection!.getStats();
      double micLevel = 0.0;
      int packetsSent = 0, packetsReceived = 0, bytesReceived = 0;
      for (final report in stats) {
        final v = report.values;
        switch (report.type) {
          case 'media-source':
            if (v['kind'] == 'audio')
              micLevel = (v['audioLevel'] as num?)?.toDouble() ?? 0.0;
          case 'outbound-rtp':
            if (v['kind'] == 'audio') {
              packetsSent = (v['packetsSent'] as num?)?.toInt() ?? 0;
              if (micLevel == 0.0)
                micLevel = (v['audioLevel'] as num?)?.toDouble() ?? 0.0;
            }
          case 'inbound-rtp':
            if (v['kind'] == 'audio') {
              packetsReceived = (v['packetsReceived'] as num?)?.toInt() ?? 0;
              bytesReceived = (v['bytesReceived'] as num?)?.toInt() ?? 0;
            }
        }
      }
      final sentDelta = packetsSent - _prevPacketsSent;
      final receivedDelta = packetsReceived - _prevPacketsReceived;
      final bytesDelta = bytesReceived - _prevBytesReceived;
      _prevPacketsSent = packetsSent;
      _prevPacketsReceived = packetsReceived;
      _prevBytesReceived = bytesReceived;
      if (sentDelta == 0 && receivedDelta == 0) {
        _stallCount++;
      } else {
        _stallCount = 0;
      }
      onAudioStatsUpdate?.call(
        AudioStats(
          micLevel: micLevel,
          sentDelta: sentDelta,
          receivedDelta: receivedDelta,
          bytesReceivedDelta: bytesDelta,
          speakerActive: packetsReceived > 0,
          isStalled: _stallCount >= 3,
        ),
      );
    } catch (e) {
      debugPrint('[Audio Check] Stats error: $e');
    }
  }

  @override
  AudioStreamStatus getAudioStatus() {
    if (_isClosed)
      return const AudioStreamStatus(localActive: false, remoteActive: false);
    final localTracks = _localStream?.getAudioTracks() ?? [];
    final localActive = localTracks.isNotEmpty && localTracks.first.enabled;
    final remoteTracks = _remoteStream?.getAudioTracks() ?? [];
    final remoteActive =
        remoteTracks.isNotEmpty && !(remoteTracks.first.muted ?? false);
    return AudioStreamStatus(
      localActive: localActive,
      remoteActive: remoteActive,
    );
  }
}
