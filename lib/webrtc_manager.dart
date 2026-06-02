import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

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

/// 테스트에서 Mock으로 교체할 수 있도록 인터페이스를 분리한다.
abstract class AbstractWebRTCManager {
  Function(RTCIceCandidate candidate)? onIceCandidate;
  Function(RTCSessionDescription offer)? onOfferCreated;
  Function(RTCSessionDescription answer)? onAnswerCreated;
  Function(RTCPeerConnectionState state)? onConnectionStateChange;
  Function(RTCIceConnectionState state)? onIceConnectionStateChange;

  Future<void> initialize();
  Future<void> createOffer();
  Future<void> createAnswer();
  Future<void> setRemoteDescription(String sdp, String type);
  Future<void> addIceCandidate(
      String candidate, String? sdpMid, int? sdpMLineIndex);
  Future<void> close();

  AudioStreamStatus getAudioStatus() =>
      const AudioStreamStatus(localActive: false, remoteActive: false);

  Function(AudioStats stats)? onAudioStatsUpdate;
}

/// WebRTC PeerConnection 래퍼.
///
/// Bug #2 대응: 자식 → 부모 순서로 해제 (peerConnection → tracks → stream)
/// Bug #3 대응: isClosed 플래그로 close() 이후 비동기 콜백을 모두 차단
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

  Function(RTCIceCandidate candidate)? onIceCandidate;
  Function(RTCSessionDescription offer)? onOfferCreated;
  Function(RTCSessionDescription answer)? onAnswerCreated;
  Function(RTCPeerConnectionState state)? onConnectionStateChange;
  Function(RTCIceConnectionState state)? onIceConnectionStateChange;
  Function(AudioStats stats)? onAudioStatsUpdate;

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
      // Bug #3: isClosed 가드
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

  Future<void> createOffer() async {
    // Bug #3: 공개 메서드 진입 가드
    if (_isClosed || _peerConnection == null) return;

    final offer = await _peerConnection!.createOffer({
      'mandatory': {'OfferToReceiveAudio': true, 'OfferToReceiveVideo': false},
    });
    if (_isClosed) return; // Bug #3: await 후 재확인
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

  Future<void> addIceCandidate(
      String candidate, String? sdpMid, int? sdpMLineIndex) async {
    if (_isClosed || _peerConnection == null) return;
    await _peerConnection!
        .addCandidate(RTCIceCandidate(candidate, sdpMid, sdpMLineIndex));
  }

  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true; // Bug #3: 선행 세팅으로 이후 콜백 차단

    _statsTimer?.cancel();
    _statsTimer = null;

    // Bug #2: 자식 → 부모 순서 해제
    await _peerConnection?.close();
    _peerConnection?.dispose(); // JNI 메모리 해제
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
      int packetsSent = 0;
      int packetsReceived = 0;
      int bytesReceived = 0;

      for (final report in stats) {
        final v = report.values;
        switch (report.type) {
          case 'media-source':
            if (v['kind'] == 'audio') {
              micLevel = (v['audioLevel'] as num?)?.toDouble() ?? 0.0;
            }
          case 'outbound-rtp':
            if (v['kind'] == 'audio') {
              packetsSent = (v['packetsSent'] as num?)?.toInt() ?? 0;
              // Fallback: 일부 Android 버전은 media-source 대신 여기서 audioLevel 제공
              if (micLevel == 0.0) {
                micLevel = (v['audioLevel'] as num?)?.toDouble() ?? 0.0;
              }
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

      final speakerStatus = packetsReceived > 0 ? 'ACTIVE' : 'SILENT';

      debugPrint('[Audio Check] 🎤 Mic Input Level: ${micLevel.toStringAsFixed(4)} | 📤 Sent Packets: +$sentDelta');
      debugPrint('[Audio Check] 🔊 Speaker Stream: $speakerStatus | 📥 Received Packets: +$receivedDelta | Bytes: +$bytesDelta');

      if (_stallCount >= 3) {
        debugPrint('[Audio Check] ⚠️  STALL ${_stallCount}s: 패킷 미흐름 — ICE 연결 상태 또는 마이크 권한 확인 필요');
      }

      onAudioStatsUpdate?.call(AudioStats(
        micLevel: micLevel,
        sentDelta: sentDelta,
        receivedDelta: receivedDelta,
        bytesReceivedDelta: bytesDelta,
        speakerActive: packetsReceived > 0,
        isStalled: _stallCount >= 3,
      ));
    } catch (e) {
      debugPrint('[Audio Check] Stats error: $e');
    }
  }

  @override
  AudioStreamStatus getAudioStatus() {
    if (_isClosed) {
      return const AudioStreamStatus(localActive: false, remoteActive: false);
    }

    final localTracks = _localStream?.getAudioTracks() ?? [];
    final localActive = localTracks.isNotEmpty && localTracks.first.enabled;

    final remoteTracks = _remoteStream?.getAudioTracks() ?? [];
    final remoteActive =
        remoteTracks.isNotEmpty && !(remoteTracks.first.muted ?? false);

    return AudioStreamStatus(localActive: localActive, remoteActive: remoteActive);
  }
}
