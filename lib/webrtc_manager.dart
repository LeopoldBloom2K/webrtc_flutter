import 'package:flutter_webrtc/flutter_webrtc.dart';

/// 테스트에서 Mock으로 교체할 수 있도록 인터페이스를 분리한다.
abstract class AbstractWebRTCManager {
  Function(RTCIceCandidate candidate)? onIceCandidate;
  Function(RTCSessionDescription offer)? onOfferCreated;
  Function(RTCSessionDescription answer)? onAnswerCreated;
  Function(RTCPeerConnectionState state)? onConnectionStateChange;

  Future<void> initialize();
  Future<void> createOffer();
  Future<void> createAnswer();
  Future<void> setRemoteDescription(String sdp, String type);
  Future<void> addIceCandidate(
      String candidate, String? sdpMid, int? sdpMLineIndex);
  Future<void> close();
}

/// WebRTC PeerConnection 래퍼.
///
/// Bug #2 대응: 자식 → 부모 순서로 해제 (peerConnection → tracks → stream)
/// Bug #3 대응: isClosed 플래그로 close() 이후 비동기 콜백을 모두 차단
class WebRTCManager extends AbstractWebRTCManager {
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  bool _isClosed = false;

  Function(RTCIceCandidate candidate)? onIceCandidate;
  Function(RTCSessionDescription offer)? onOfferCreated;
  Function(RTCSessionDescription answer)? onAnswerCreated;
  Function(RTCPeerConnectionState state)? onConnectionStateChange;

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
      // Bug #3: isClosed 가드
      if (_isClosed) return;
      onConnectionStateChange?.call(state);
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
  }
}
