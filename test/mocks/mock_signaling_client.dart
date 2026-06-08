import 'dart:async';

import 'package:webrtc_flutter/signaling_client.dart';

/// 테스트용 SignalingClient Mock.
/// 실제 WebSocket 없이 콜백 흐름을 테스트한다.
class MockSignalingClient extends AbstractSignalingClient {
  // 실제로 전송된 메시지 기록 (검증용)
  final List<Map<String, dynamic>> sentMessages = [];

  // 연결 성공 여부를 제어 (기본: 성공)
  bool shouldConnectSucceed = true;

  // disconnect() 호출 횟수
  int disconnectCallCount = 0;

  // intentionalDisconnect 플래그 노출 (Bug #5 검증용)
  bool intentionalDisconnect = false;

  @override
  Future<void> connect(String url) async {
    if (shouldConnectSucceed) {
      onConnected?.call();
    } else {
      onDisconnected?.call();
    }
  }

  /// 서버에서 메시지가 온 것처럼 시뮬레이션한다.
  void simulateIncomingMessage(Map<String, dynamic> message) {
    onMessage?.call(message);
  }

  /// 서버 연결이 끊긴 것처럼 시뮬레이션한다.
  void simulateDisconnect() {
    if (!intentionalDisconnect) onDisconnected?.call();
    intentionalDisconnect = false;
  }

  @override
  void sendCallRequest() => sentMessages.add({'type': 'call_request'});

  @override
  void sendCallAccept() => sentMessages.add({'type': 'call_accept'});

  @override
  void sendCallReject() => sentMessages.add({'type': 'call_reject'});

  @override
  void sendCallCancel() => sentMessages.add({'type': 'call_cancel'});

  @override
  void sendHangUp() => sentMessages.add({'type': 'hang_up'});

  @override
  void sendOffer(String sdp) => sentMessages.add({'type': 'offer', 'sdp': sdp});

  @override
  void sendAnswer(String sdp) =>
      sentMessages.add({'type': 'answer', 'sdp': sdp});

  @override
  void sendIce(String candidate, String? sdpMid, int? sdpMLineIndex) =>
      sentMessages.add({
        'type': 'ice',
        'candidate': candidate,
        'sdpMid': sdpMid,
        'sdpMLineIndex': sdpMLineIndex,
      });

  @override
  void disconnect() {
    intentionalDisconnect = true; // Bug #5: 의도적 종료 표시
    disconnectCallCount++;
  }

  bool get lastSentType =>
      sentMessages.isNotEmpty ? sentMessages.last['type'] : null;
}
