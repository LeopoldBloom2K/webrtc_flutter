// lib/webrtc_manager.dart  (VocalCrypt 통합 버전)
//
// 변경 사항:
//   - VocalCryptService 주입 지원
//   - initialize()에서 마이크 스트림 획득 후 VocalCrypt 처리 상태 기록
//   - protectAndRecord(): 레퍼런스 오디오를 보호하는 공개 메서드 추가
//   - vocalCryptEnabled 플래그로 ON/OFF 가능

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:record/record.dart';          // pub: record (마이크 녹음)
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
  const AudioStreamStatus({required this.localActive, required this.remoteActive});
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
  Future<void> addIceCandidate(String candidate, String? sdpMid, int? sdpMLineIndex);
  Future<void> close();

  AudioStreamStatus getAudioStatus() =>
      const AudioStreamStatus(localActive: false, remoteActive: false);

  /// 통화 전 레퍼런스 오디오 녹음 + VocalCrypt 보호
  /// [durationSeconds]: 녹음 시간 (기본 3초)
  Future<VocalCryptResult?> captureAndProtect({int durationSeconds = 3}) async => null;
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

  Function(RTCIceCandidate candidate)? onIceCandidate;
  Function(RTCSessionDescription offer)? onOfferCreated;
  Function(RTCSessionDescription answer)? onAnswerCreated;
  Function(RTCPeerConnectionState state)? onConnectionStateChange;
  Function(RTCIceConnectionState state)? onIceConnectionStateChange;
  Function(AudioStats stats)? onAudioStatsUpdate;
  Function(VocalCryptStatus status, String message)? onVocalCryptStatus;

  WebRTCManager({
    this.vocalCryptService,
    this.vocalCryptEnabled = true,
  });

  static const _iceServers = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
    ],
    'iceCandidatePoolSize': 10,
  };

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
  Future<VocalCryptResult?> captureAndProtect({int durationSeconds = 3}) async {
    if (!vocalCryptEnabled || vocalCryptService == null) return null;
    if (_isClosed) return null;

    // 서버 생존 확인
    final serverAlive = await vocalCryptService!.isServerAlive();
    if (!serverAlive) {
      _notifyVocalCrypt(VocalCryptStatus.error, 'VocalCrypt 서버에 연결할 수 없습니다');
      return null;
    }

    // 마이크 녹음
    _notifyVocalCrypt(VocalCryptStatus.recording, '음성 샘플 녹음 중... (${durationSeconds}초)');
    final wavBytes = await _recordMicrophone(durationSeconds);
    if (wavBytes == null) {
      _notifyVocalCrypt(VocalCryptStatus.error, '녹음 실패');
      return null;
    }

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
      _notifyVocalCrypt(VocalCryptStatus.error, result.errorMessage ?? '알 수 없는 오류');
    }
    return result;
  }

  void _notifyVocalCrypt(VocalCryptStatus status, String message) {
    _vcStatus = status;
    debugPrint('[VocalCrypt] $status: $message');
    onVocalCryptStatus?.call(status, message);
  }

  Future<Uint8List?> _recordMicrophone(int seconds) async {
    try {
      final recorder = AudioRecorder();
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/vc_sample_${DateTime.now().millisecondsSinceEpoch}.wav';

      if (!await recorder.hasPermission()) return null;

      await recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 48000,
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

  // 보호된 오디오 바이트 반환 (외부에서 파일로 저장하거나 전송 시 사용)
  Uint8List? get lastProtectedAudio => _lastProtectedAudio;
  VocalCryptStatus get vocalCryptStatus => _vcStatus;

  // ── 기존 WebRTC 메서드 (변경 없음) ──────────────────────────
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

  Future<void> setRemoteDescription(String sdp, String type) async {
    if (_isClosed || _peerConnection == null) return;
    await _peerConnection!.setRemoteDescription(RTCSessionDescription(sdp, type));
  }

  Future<void> addIceCandidate(String candidate, String? sdpMid, int? sdpMLineIndex) async {
    if (_isClosed || _peerConnection == null) return;
    await _peerConnection!.addCandidate(RTCIceCandidate(candidate, sdpMid, sdpMLineIndex));
  }

  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    _statsTimer?.cancel();
    _statsTimer = null;
    await _peerConnection?.close();
    _peerConnection?.dispose();
    _peerConnection = null;
    if (_localStream != null) {
      for (final track in _localStream!.getTracks()) await track.stop();
      await _localStream!.dispose();
      _localStream = null;
    }
    _remoteStream = null;
  }

  void _startStatsMonitor() {
    _statsTimer?.cancel();
    _prevPacketsSent = 0; _prevPacketsReceived = 0;
    _prevBytesReceived = 0; _stallCount = 0;
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) => _checkAudioStats());
  }

  Future<void> _checkAudioStats() async {
    if (_isClosed || _peerConnection == null) return;
    try {
      final stats = await _peerConnection!.getStats();
      double micLevel = 0.0; int packetsSent = 0, packetsReceived = 0, bytesReceived = 0;
      for (final report in stats) {
        final v = report.values;
        switch (report.type) {
          case 'media-source':
            if (v['kind'] == 'audio') micLevel = (v['audioLevel'] as num?)?.toDouble() ?? 0.0;
          case 'outbound-rtp':
            if (v['kind'] == 'audio') {
              packetsSent = (v['packetsSent'] as num?)?.toInt() ?? 0;
              if (micLevel == 0.0) micLevel = (v['audioLevel'] as num?)?.toDouble() ?? 0.0;
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
      _prevPacketsSent = packetsSent; _prevPacketsReceived = packetsReceived;
      _prevBytesReceived = bytesReceived;
      if (sentDelta == 0 && receivedDelta == 0) _stallCount++; else _stallCount = 0;
      onAudioStatsUpdate?.call(AudioStats(
        micLevel: micLevel, sentDelta: sentDelta, receivedDelta: receivedDelta,
        bytesReceivedDelta: bytesDelta, speakerActive: packetsReceived > 0,
        isStalled: _stallCount >= 3,
      ));
    } catch (e) { debugPrint('[Audio Check] Stats error: $e'); }
  }

  @override
  AudioStreamStatus getAudioStatus() {
    if (_isClosed) return const AudioStreamStatus(localActive: false, remoteActive: false);
    final localTracks = _localStream?.getAudioTracks() ?? [];
    final localActive = localTracks.isNotEmpty && localTracks.first.enabled;
    final remoteTracks = _remoteStream?.getAudioTracks() ?? [];
    final remoteActive = remoteTracks.isNotEmpty && !(remoteTracks.first.muted ?? false);
    return AudioStreamStatus(localActive: localActive, remoteActive: remoteActive);
  }
}