import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

typedef MessageCallback = void Function(Map<String, dynamic> message);
typedef VoidCallback = void Function();

/// 테스트에서 Mock으로 교체할 수 있도록 인터페이스를 분리한다.
abstract class AbstractSignalingClient {
  MessageCallback? onMessage;
  VoidCallback? onConnected;
  VoidCallback? onDisconnected;

  Future<void> connect(String url);
  void sendCallRequest();
  void sendCallAccept();
  void sendCallReject();
  void sendCallCancel();
  void sendHangUp();
  void sendOffer(String sdp);
  void sendAnswer(String sdp);
  void sendIce(String candidate, String? sdpMid, int? sdpMLineIndex);
  void disconnect();
}

/// WebSocket 시그널링 클라이언트.
///
/// Bug #5 대응: intentionalDisconnect 플래그로 dispose() 시점의
/// sink.close()가 onDisconnected 콜백을 발화하지 않도록 억제한다.
class SignalingClient extends AbstractSignalingClient {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  bool _intentionalDisconnect = false;

  MessageCallback? onMessage;
  VoidCallback? onConnected;
  VoidCallback? onDisconnected;

  Future<void> connect(String url) async {
    _intentionalDisconnect = false;
    try {
      _channel = WebSocketChannel.connect(Uri.parse(url));
      _subscription = _channel!.stream.listen(
        _handleData,
        onDone: _handleDone,
        onError: _handleError,
        cancelOnError: false,
      );
      await _channel!.ready;
      onConnected?.call();
    } catch (_) {
      await _subscription?.cancel();
      _subscription = null;
      _channel = null;
      onDisconnected?.call();
    }
  }

  void _handleData(dynamic data) {
    try {
      final message = jsonDecode(data as String) as Map<String, dynamic>;
      onMessage?.call(message);
    } catch (_) {}
  }

  void _handleDone() {
    // Bug #5: 의도적 종료(disconnect() 호출)이면 콜백 억제
    if (!_intentionalDisconnect) onDisconnected?.call();
    _intentionalDisconnect = false;
  }

  void _handleError(Object error) {
    if (!_intentionalDisconnect) onDisconnected?.call();
    _intentionalDisconnect = false;
  }

  void send(Map<String, dynamic> message) {
    _channel?.sink.add(jsonEncode(message));
  }

  // 통화 제어 메시지 (Bug #1: call_request/accept/reject/cancel 추가)
  void sendCallRequest() => send({'type': 'call_request'});
  void sendCallAccept() => send({'type': 'call_accept'});
  void sendCallReject() => send({'type': 'call_reject'});
  void sendCallCancel() => send({'type': 'call_cancel'});
  void sendHangUp() => send({'type': 'hang_up'});

  // WebRTC SDP / ICE 메시지
  void sendOffer(String sdp) => send({'type': 'offer', 'sdp': sdp});
  void sendAnswer(String sdp) => send({'type': 'answer', 'sdp': sdp});
  void sendIce(String candidate, String? sdpMid, int? sdpMLineIndex) => send({
        'type': 'ice',
        'candidate': candidate,
        'sdpMid': sdpMid,
        'sdpMLineIndex': sdpMLineIndex,
      });

  void disconnect() {
    _intentionalDisconnect = true; // Bug #5: 의도적 종료 표시
    _subscription?.cancel();
    _channel?.sink.close(1000);
    _subscription = null;
    _channel = null;
  }
}
