import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:webrtc_flutter/webrtc_manager.dart';

/// 테스트용 WebRTCManager Mock.
/// flutter_webrtc 네이티브 코드 없이 상태 전이를 테스트한다.
class MockWebRTCManager extends AbstractWebRTCManager {
  bool initialized = false;
  bool closed = false;
  bool offerCreated = false;
  bool answerCreated = false;
  String? lastRemoteSdp;
  String? lastRemoteSdpType;
  int initializeCallCount = 0;
  int closeCallCount = 0;

  // initialize()가 완료된 후 즉시 연결 상태를 시뮬레이션할지 여부
  bool autoFireConnected = false;

  @override
  Future<void> initialize() async {
    initializeCallCount++;
    initialized = true;
  }

  @override
  Future<void> createOffer() async {
    if (closed) return;
    offerCreated = true;
    final sdp = RTCSessionDescription('v=0\r\n...mock offer sdp', 'offer');
    onOfferCreated?.call(sdp);
  }

  @override
  Future<void> createAnswer() async {
    if (closed) return;
    answerCreated = true;
    final sdp = RTCSessionDescription('v=0\r\n...mock answer sdp', 'answer');
    onAnswerCreated?.call(sdp);
  }

  @override
  Future<void> setRemoteDescription(String sdp, String type) async {
    if (closed) return;
    lastRemoteSdp = sdp;
    lastRemoteSdpType = type;
  }

  @override
  Future<void> addIceCandidate(
      String candidate, String? sdpMid, int? sdpMLineIndex) async {}

  @override
  Future<void> close() async {
    closed = true;
    closeCallCount++;
  }

  /// 외부에서 연결 상태 변화를 시뮬레이션한다.
  void simulateConnectionState(RTCPeerConnectionState state) {
    if (!closed) onConnectionStateChange?.call(state);
  }

  /// 외부에서 ICE candidate를 시뮬레이션한다.
  void simulateIceCandidate(RTCIceCandidate candidate) {
    if (!closed) onIceCandidate?.call(candidate);
  }
}
