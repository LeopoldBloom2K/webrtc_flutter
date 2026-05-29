import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../mocks/mock_webrtc_manager.dart';

void main() {
  group('Bug #2/#3 — isClosed 플래그와 해제 순서', () {
    late MockWebRTCManager manager;

    setUp(() {
      manager = MockWebRTCManager();
    });

    test('close() 호출 후 closed=true', () async {
      await manager.close();
      expect(manager.closed, isTrue);
    });

    test('close()는 멱등성: 두 번 호출해도 closeCallCount=2이고 에러 없음', () async {
      await manager.close();
      await manager.close();
      expect(manager.closeCallCount, 2);
    });

    test('close() 후 createOffer()는 onOfferCreated를 호출하지 않음', () async {
      bool called = false;
      manager.onOfferCreated = (_) => called = true;

      await manager.close();
      await manager.createOffer();
      expect(called, isFalse);
    });

    test('close() 후 createAnswer()는 onAnswerCreated를 호출하지 않음', () async {
      bool called = false;
      manager.onAnswerCreated = (_) => called = true;

      await manager.close();
      await manager.createAnswer();
      expect(called, isFalse);
    });

    test('close() 후 simulateConnectionState는 콜백 미호출', () {
      int callCount = 0;
      manager.onConnectionStateChange = (_) => callCount++;

      manager.close();
      manager.simulateConnectionState(RTCPeerConnectionState.RTCPeerConnectionStateConnected);
      expect(callCount, 0);
    });
  });

  group('WebRTCManager 정상 흐름', () {
    late MockWebRTCManager manager;

    setUp(() {
      manager = MockWebRTCManager();
    });

    test('initialize() 호출 후 initialized=true', () async {
      await manager.initialize();
      expect(manager.initialized, isTrue);
    });

    test('createOffer() 호출 시 onOfferCreated 콜백 발화', () async {
      RTCSessionDescription? offer;
      manager.onOfferCreated = (sdp) => offer = sdp;

      await manager.initialize();
      await manager.createOffer();

      expect(offer, isNotNull);
      expect(offer!.type, 'offer');
    });

    test('createAnswer() 호출 시 onAnswerCreated 콜백 발화', () async {
      RTCSessionDescription? answer;
      manager.onAnswerCreated = (sdp) => answer = sdp;

      await manager.initialize();
      await manager.createAnswer();

      expect(answer, isNotNull);
      expect(answer!.type, 'answer');
    });

    test('setRemoteDescription()은 sdp와 type을 저장', () async {
      await manager.setRemoteDescription('mock-sdp', 'offer');
      expect(manager.lastRemoteSdp, 'mock-sdp');
      expect(manager.lastRemoteSdpType, 'offer');
    });

    test('RTCPeerConnectionStateConnected → onConnectionStateChange 발화', () {
      RTCPeerConnectionState? received;
      manager.onConnectionStateChange = (s) => received = s;

      manager.simulateConnectionState(
          RTCPeerConnectionState.RTCPeerConnectionStateConnected);

      expect(received,
          RTCPeerConnectionState.RTCPeerConnectionStateConnected);
    });

    test('ICE candidate 시뮬레이션 → onIceCandidate 발화', () {
      RTCIceCandidate? received;
      manager.onIceCandidate = (c) => received = c;

      final candidate = RTCIceCandidate('candidate:abc', 'audio', 0);
      manager.simulateIceCandidate(candidate);

      expect(received, isNotNull);
      expect(received!.candidate, 'candidate:abc');
    });
  });
}
