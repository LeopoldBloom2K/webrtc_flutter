import 'package:flutter_test/flutter_test.dart';

import '../mocks/mock_signaling_client.dart';

void main() {
  group('MockSignalingClient — 시그널링 메시지 포맷', () {
    late MockSignalingClient client;

    setUp(() {
      client = MockSignalingClient();
    });

    test('sendCallRequest()는 type=call_request 전송', () {
      client.sendCallRequest();
      expect(client.sentMessages.last['type'], 'call_request');
    });

    test('sendCallAccept()는 type=call_accept 전송', () {
      client.sendCallAccept();
      expect(client.sentMessages.last['type'], 'call_accept');
    });

    test('sendCallReject()는 type=call_reject 전송', () {
      client.sendCallReject();
      expect(client.sentMessages.last['type'], 'call_reject');
    });

    test('sendCallCancel()는 type=call_cancel 전송', () {
      client.sendCallCancel();
      expect(client.sentMessages.last['type'], 'call_cancel');
    });

    test('sendHangUp()는 type=hang_up 전송', () {
      client.sendHangUp();
      expect(client.sentMessages.last['type'], 'hang_up');
    });

    test('sendOffer()는 type=offer와 sdp 포함', () {
      client.sendOffer('mock-sdp-string');
      final msg = client.sentMessages.last;
      expect(msg['type'], 'offer');
      expect(msg['sdp'], 'mock-sdp-string');
    });

    test('sendAnswer()는 type=answer와 sdp 포함', () {
      client.sendAnswer('answer-sdp');
      final msg = client.sentMessages.last;
      expect(msg['type'], 'answer');
      expect(msg['sdp'], 'answer-sdp');
    });

    test('sendIce()는 candidate/sdpMid/sdpMLineIndex 포함', () {
      client.sendIce('candidate:abc', 'audio', 0);
      final msg = client.sentMessages.last;
      expect(msg['type'], 'ice');
      expect(msg['candidate'], 'candidate:abc');
      expect(msg['sdpMid'], 'audio');
      expect(msg['sdpMLineIndex'], 0);
    });
  });

  group('Bug #5 — intentionalDisconnect 플래그', () {
    test('disconnect() 호출 시 intentionalDisconnect=true로 설정', () {
      final client = MockSignalingClient();
      expect(client.intentionalDisconnect, isFalse);
      client.disconnect();
      expect(client.intentionalDisconnect, isTrue);
    });

    test('disconnect() 후 simulateDisconnect()는 onDisconnected 미호출', () {
      final client = MockSignalingClient();
      int callCount = 0;
      client.onDisconnected = () => callCount++;

      client.disconnect(); // intentionalDisconnect = true
      client.simulateDisconnect(); // 억제되어야 함
      expect(callCount, 0);
    });

    test('의도적이지 않은 disconnect는 onDisconnected 호출', () {
      final client = MockSignalingClient();
      int callCount = 0;
      client.onDisconnected = () => callCount++;

      client.simulateDisconnect(); // intentionalDisconnect = false → 콜백 발화
      expect(callCount, 1);
    });
  });

  group('SignalingClient 연결 콜백', () {
    test('연결 성공 시 onConnected 호출', () async {
      final client = MockSignalingClient();
      bool connected = false;
      client.onConnected = () => connected = true;

      await client.connect('ws://localhost:8080');
      expect(connected, isTrue);
    });

    test('연결 실패 시 onDisconnected 호출', () async {
      final client = MockSignalingClient()..shouldConnectSucceed = false;
      bool disconnected = false;
      client.onDisconnected = () => disconnected = true;

      await client.connect('ws://invalid');
      expect(disconnected, isTrue);
    });

    test('수신 메시지가 onMessage 콜백에 전달됨', () async {
      final client = MockSignalingClient();
      Map<String, dynamic>? received;
      client.onMessage = (msg) => received = msg;

      await client.connect('ws://localhost:8080');
      client.simulateIncomingMessage({'type': 'call_request'});
      expect(received, isNotNull);
      expect(received!['type'], 'call_request');
    });
  });
}
