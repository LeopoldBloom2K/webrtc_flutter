import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:webrtc_flutter/call_screen.dart';

import '../mocks/mock_signaling_client.dart';
import '../mocks/mock_webrtc_manager.dart';

Widget _buildTestApp(Widget child) => MaterialApp(home: child);

/// Mock을 주입한 CallScreen.
/// microphonePermissionChecker를 통해 permission_handler 플러그인 호출 우회.
CallScreen _makeScreen({
  required MockSignalingClient signalingClient,
  required MockWebRTCManager webRTCManager,
  bool micGranted = true,
}) =>
    CallScreen(
      signalingClient: signalingClient,
      webRTCManager: webRTCManager,
      initialServerUrl: 'ws://test:8080',
      microphonePermissionChecker: () async => micGranted,
    );

/// CircularProgressIndicator(무한 애니메이션) 때문에 pumpAndSettle은 쓸 수 없다.
/// 대신 pump()를 여러 번 호출해 비동기 완료를 기다린다.
Future<void> pumpAsync(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

/// 서버 연결된 상태(IDLE)로 위젯을 띄운다.
Future<(MockSignalingClient, MockWebRTCManager)> pumpConnected(
    WidgetTester tester) async {
  final sc = MockSignalingClient();
  final wm = MockWebRTCManager();
  await tester.pumpWidget(_buildTestApp(_makeScreen(
    signalingClient: sc,
    webRTCManager: wm,
  )));
  await tester.pump();
  return (sc, wm);
}

/// 발신 → call_accept → RTCConnected 순서로 IN_CALL 상태까지 진행한다.
Future<(MockSignalingClient, MockWebRTCManager)> pumpInCall(
    WidgetTester tester) async {
  final (sc, wm) = await pumpConnected(tester);

  await tester.tap(find.text('발신'));
  await tester.pump();

  sc.simulateIncomingMessage({'type': 'call_accept'});
  await pumpAsync(tester); // connecting 상태 (spinner) — pumpAndSettle 불가

  wm.simulateConnectionState(
      RTCPeerConnectionState.RTCPeerConnectionStateConnected);
  await tester.pump();

  return (sc, wm);
}

void main() {
  // ─────────────────────────────────────────────
  group('초기 상태 (IDLE + 서버 연결됨)', () {
    testWidgets('앱 제목이 표시된다', (tester) async {
      await pumpConnected(tester);
      expect(find.text('딥보이스 보안 통화'), findsOneWidget);
    });

    testWidgets('서버 연결 후 "발신" 버튼이 표시된다', (tester) async {
      await pumpConnected(tester);
      expect(find.text('발신'), findsOneWidget);
    });

    testWidgets('서버 미연결 시 발신 버튼 대신 안내 텍스트 표시', (tester) async {
      final sc = MockSignalingClient()..shouldConnectSucceed = false;
      final wm = MockWebRTCManager();
      await tester.pumpWidget(_buildTestApp(_makeScreen(
        signalingClient: sc,
        webRTCManager: wm,
        micGranted: true,
      )));
      await tester.pump();
      expect(find.textContaining('연결 후 통화'), findsOneWidget);
      expect(find.text('발신'), findsNothing);
    });
  });

  // ─────────────────────────────────────────────
  group('Bug #1 — 발신 흐름', () {
    testWidgets('발신 버튼 탭 → CALLING 상태 (취소 버튼 표시)', (tester) async {
      await pumpConnected(tester);
      await tester.tap(find.text('발신'));
      await tester.pump();
      expect(find.text('취소'), findsOneWidget);
      expect(find.text('발신'), findsNothing);
    });

    testWidgets('발신 탭 → call_request 전송', (tester) async {
      final (sc, _) = await pumpConnected(tester);
      await tester.tap(find.text('발신'));
      await tester.pump();
      expect(sc.sentMessages.any((m) => m['type'] == 'call_request'), isTrue);
    });

    testWidgets('취소 버튼 탭 → call_cancel 전송 + IDLE 복귀', (tester) async {
      final (sc, _) = await pumpConnected(tester);
      await tester.tap(find.text('발신'));
      await tester.pump();
      await tester.tap(find.text('취소'));
      await tester.pump();
      expect(sc.sentMessages.any((m) => m['type'] == 'call_cancel'), isTrue);
      expect(find.text('발신'), findsOneWidget);
    });
  });

  // ─────────────────────────────────────────────
  group('Bug #1 — 수신 흐름', () {
    testWidgets('call_request 수신 → 받기/거절 버튼 표시', (tester) async {
      final (sc, _) = await pumpConnected(tester);
      sc.simulateIncomingMessage({'type': 'call_request'});
      await tester.pump();
      expect(find.text('받기'), findsOneWidget);
      expect(find.text('거절'), findsOneWidget);
      expect(find.text('발신'), findsNothing);
    });

    testWidgets('거절 버튼 탭 → call_reject 전송 + IDLE 복귀', (tester) async {
      final (sc, _) = await pumpConnected(tester);
      sc.simulateIncomingMessage({'type': 'call_request'});
      await tester.pump();
      await tester.tap(find.text('거절'));
      await tester.pump();
      expect(sc.sentMessages.any((m) => m['type'] == 'call_reject'), isTrue);
      expect(find.text('발신'), findsOneWidget);
    });

    testWidgets('받기 버튼 탭 → call_accept 전송 + WebRTC initialize 호출',
        (tester) async {
      final (sc, wm) = await pumpConnected(tester);
      sc.simulateIncomingMessage({'type': 'call_request'});
      await tester.pump();
      await tester.tap(find.text('받기'));
      await pumpAsync(tester); // connecting 상태 spinner — pumpAndSettle 불가
      expect(sc.sentMessages.any((m) => m['type'] == 'call_accept'), isTrue);
      expect(wm.initializeCallCount, 1);
    });
  });

  // ─────────────────────────────────────────────
  group('Bug #6 — call_accept 수신 시 CONNECTING 전환', () {
    testWidgets('call_accept 수신 → createOffer 호출 + WebRTC initialized',
        (tester) async {
      final (sc, wm) = await pumpConnected(tester);
      await tester.tap(find.text('발신'));
      await tester.pump();
      sc.simulateIncomingMessage({'type': 'call_accept'});
      await pumpAsync(tester);
      expect(wm.offerCreated, isTrue);
      expect(wm.initializeCallCount, 1);
    });
  });

  // ─────────────────────────────────────────────
  group('SDP / ICE 교환', () {
    testWidgets('offer 수신 → setRemoteDescription + createAnswer 호출',
        (tester) async {
      final (sc, wm) = await pumpConnected(tester);
      sc.simulateIncomingMessage({'type': 'call_request'});
      await tester.pump();
      await tester.tap(find.text('받기'));
      await pumpAsync(tester);
      sc.simulateIncomingMessage({'type': 'offer', 'sdp': 'v=0\r\nmock'});
      await pumpAsync(tester);
      expect(wm.lastRemoteSdp, 'v=0\r\nmock');
      expect(wm.lastRemoteSdpType, 'offer');
      expect(wm.answerCreated, isTrue);
    });

    testWidgets('createOffer 완료 → sendOffer 호출', (tester) async {
      final (sc, wm) = await pumpConnected(tester);
      await tester.tap(find.text('발신'));
      await tester.pump();
      sc.simulateIncomingMessage({'type': 'call_accept'});
      await pumpAsync(tester);
      expect(sc.sentMessages.any((m) => m['type'] == 'offer'), isTrue);
    });

    testWidgets('createAnswer 완료 → sendAnswer 호출', (tester) async {
      final (sc, wm) = await pumpConnected(tester);
      sc.simulateIncomingMessage({'type': 'call_request'});
      await tester.pump();
      await tester.tap(find.text('받기'));
      await pumpAsync(tester);
      sc.simulateIncomingMessage({'type': 'offer', 'sdp': 'mock-offer'});
      await pumpAsync(tester);
      expect(sc.sentMessages.any((m) => m['type'] == 'answer'), isTrue);
    });
  });

  // ─────────────────────────────────────────────
  group('Bug #4 — stale WebRTC 콜백 무시', () {
    testWidgets('IDLE 상태에서 RTCConnected 콜백 도착해도 UI 변화 없음',
        (tester) async {
      final (_, wm) = await pumpConnected(tester);
      wm.simulateConnectionState(
          RTCPeerConnectionState.RTCPeerConnectionStateConnected);
      await tester.pump();
      // stale 콜백은 무시 → 여전히 발신 버튼
      expect(find.text('발신'), findsOneWidget);
    });
  });

  // ─────────────────────────────────────────────
  group('통화 종료 흐름', () {
    testWidgets('IN_CALL 상태에서 Hang Up 버튼 표시', (tester) async {
      await pumpInCall(tester);
      expect(find.text('Hang Up'), findsOneWidget);
    });

    testWidgets('Hang Up 탭 → hang_up 전송 + IDLE 복귀', (tester) async {
      final (sc, wm) = await pumpInCall(tester);
      await tester.tap(find.text('Hang Up'));
      await tester.pump();
      expect(sc.sentMessages.any((m) => m['type'] == 'hang_up'), isTrue);
      expect(wm.closed, isTrue);
      expect(find.text('발신'), findsOneWidget);
    });

    testWidgets('상대방 hang_up 수신 → IDLE 복귀 + "상대방 종료" 메시지', (tester) async {
      final (sc, wm) = await pumpInCall(tester);
      sc.simulateIncomingMessage({'type': 'hang_up'});
      await tester.pump();
      expect(wm.closed, isTrue);
      expect(find.textContaining('상대방이 통화를 종료'), findsOneWidget);
      expect(find.text('발신'), findsOneWidget);
    });
  });

  // ─────────────────────────────────────────────
  group('Bug #5 — 서버 단절 vs 의도적 종료', () {
    testWidgets('비의도적 서버 단절 → "서버 연결 끊김" 메시지', (tester) async {
      final (sc, _) = await pumpConnected(tester);
      sc.simulateDisconnect();
      await tester.pump();
      expect(find.textContaining('서버 연결 끊김'), findsOneWidget);
    });

    testWidgets('dispose 시 intentionalDisconnect=true → onDisconnected 미발화',
        (tester) async {
      final sc = MockSignalingClient();
      final wm = MockWebRTCManager();
      bool disconnected = false;
      sc.onDisconnected = () => disconnected = true;

      await tester.pumpWidget(_buildTestApp(_makeScreen(
        signalingClient: sc,
        webRTCManager: wm,
        micGranted: true,
      )));
      await tester.pump();
      await tester.pumpWidget(_buildTestApp(const SizedBox()));
      await tester.pump();

      expect(sc.disconnectCallCount, 1);
      expect(disconnected, isFalse);
    });
  });

  // ─────────────────────────────────────────────
  group('수신 취소 / 거절 흐름', () {
    testWidgets('call_cancel 수신 → IDLE 복귀', (tester) async {
      final (sc, _) = await pumpConnected(tester);
      sc.simulateIncomingMessage({'type': 'call_request'});
      await tester.pump();
      sc.simulateIncomingMessage({'type': 'call_cancel'});
      await tester.pump();
      expect(find.text('발신'), findsOneWidget);
      expect(find.textContaining('취소했습니다'), findsOneWidget);
    });

    testWidgets('call_reject 수신 → IDLE 복귀 + "거절" 메시지', (tester) async {
      final (sc, _) = await pumpConnected(tester);
      await tester.tap(find.text('발신'));
      await tester.pump();
      sc.simulateIncomingMessage({'type': 'call_reject'});
      await tester.pump();
      expect(find.text('발신'), findsOneWidget);
      expect(find.textContaining('거절'), findsOneWidget);
    });
  });

  // ─────────────────────────────────────────────
  group('ICE candidate 수신 처리', () {
    testWidgets('ice 메시지 수신 → addIceCandidate 호출 (에러 없음)', (tester) async {
      final (sc, _) = await pumpConnected(tester);
      sc.simulateIncomingMessage({
        'type': 'ice',
        'candidate': 'candidate:abc',
        'sdpMid': 'audio',
        'sdpMLineIndex': 0,
      });
      await tester.pump();
    });

    testWidgets('candidate 필드가 null인 ice 메시지 → 무시됨', (tester) async {
      final (sc, _) = await pumpConnected(tester);
      sc.simulateIncomingMessage({
        'type': 'ice',
        'sdpMid': 'audio',
        'sdpMLineIndex': 0,
      });
      await tester.pump();
    });
  });

  // ─────────────────────────────────────────────
  group('RTCPeerConnection 상태 전이', () {
    testWidgets('RTCConnected → inCall 상태, Hang Up 버튼 표시', (tester) async {
      final (sc, wm) = await pumpConnected(tester);
      await tester.tap(find.text('발신'));
      await tester.pump();
      sc.simulateIncomingMessage({'type': 'call_accept'});
      await pumpAsync(tester);

      wm.simulateConnectionState(
          RTCPeerConnectionState.RTCPeerConnectionStateConnected);
      await tester.pump();

      expect(find.text('Hang Up'), findsOneWidget);
      expect(find.textContaining('통화 중'), findsOneWidget);
    });

    testWidgets('RTCFailed → 통화 종료 + IDLE 복귀', (tester) async {
      final (sc, wm) = await pumpInCall(tester);
      wm.simulateConnectionState(
          RTCPeerConnectionState.RTCPeerConnectionStateFailed);
      await tester.pump();
      expect(find.text('발신'), findsOneWidget);
    });
  });

  // ─────────────────────────────────────────────
  group('마이크 권한 거부', () {
    testWidgets('권한 거부 시 IDLE로 복귀 + 안내 메시지', (tester) async {
      final sc = MockSignalingClient();
      final wm = MockWebRTCManager();
      await tester.pumpWidget(_buildTestApp(CallScreen(
        signalingClient: sc,
        webRTCManager: wm,
        initialServerUrl: 'ws://test:8080',
        microphonePermissionChecker: () async => false, // 거부
      )));
      await tester.pump();

      // 발신 흐름에서 권한 거부
      await tester.tap(find.text('발신'));
      await tester.pump();
      sc.simulateIncomingMessage({'type': 'call_accept'});
      await pumpAsync(tester);

      expect(find.text('발신'), findsOneWidget);
      expect(find.textContaining('마이크 권한'), findsOneWidget);
    });
  });
}
