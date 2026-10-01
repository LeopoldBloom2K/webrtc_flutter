import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webrtc_flutter/call_screen.dart';
import 'package:webrtc_flutter/webrtc_manager.dart' show AudioStats;

import '../mocks/mock_audio_relay.dart';
import '../mocks/mock_signaling_client.dart';
import '../mocks/mock_webrtc_manager.dart';

Widget _buildTestApp(Widget child) => MaterialApp(home: child);

/// 화면이 만든 음성 중계 Mock. 테스트마다 setUp 에서 비운다.
final List<MockAudioRelay> relays = [];

/// true 면 다음에 만들어지는 음성 중계의 start() 가 실패한다.
bool failRelayStart = false;

/// Mock을 주입한 CallScreen.
/// microphonePermissionChecker를 통해 permission_handler 플러그인 호출 우회.
/// audioRelayFactory를 통해 마이크·재생·소켓 없이 음성 중계를 대체.
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
      audioRelayFactory: (url, sessionId, role) {
        final r = MockAudioRelay(url, sessionId, role, failStart: failRelayStart);
        relays.add(r);
        return r;
      },
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

/// 발신 → call_accept → session_start(음성 채널 시작) 순서로 IN_CALL 상태까지 진행한다.
Future<(MockSignalingClient, MockWebRTCManager)> pumpInCall(
    WidgetTester tester) async {
  final (sc, wm) = await pumpConnected(tester);

  await tester.tap(find.text('발신'));
  await tester.pump();

  sc.simulateIncomingMessage({'type': 'call_accept'});
  await pumpAsync(tester); // connecting 상태 (spinner) — pumpAndSettle 불가

  sc.simulateIncomingMessage(
      {'type': 'session_start', 'session_id': 's1', 'role': 'caller'});
  await pumpAsync(tester);

  return (sc, wm);
}

const _stats = AudioStats(
  micLevel: 0.05,
  sentDelta: 10,
  receivedDelta: 10,
  bytesReceivedDelta: 32000,
  speakerActive: true,
  isStalled: false,
);

void main() {
  setUp(() {
    relays.clear();
    failRelayStart = false;
  });

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

    testWidgets('받기 버튼 탭 → call_accept 전송 + CONNECTING (WebRTC 미사용)',
        (tester) async {
      final (sc, wm) = await pumpConnected(tester);
      sc.simulateIncomingMessage({'type': 'call_request'});
      await tester.pump();
      await tester.tap(find.text('받기'));
      await pumpAsync(tester); // connecting 상태 spinner — pumpAndSettle 불가
      expect(sc.sentMessages.any((m) => m['type'] == 'call_accept'), isTrue);
      expect(find.text('종료'), findsOneWidget);
      expect(wm.initializeCallCount, 0);
    });
  });

  // ─────────────────────────────────────────────
  group('Bug #6 — call_accept 수신 시 CONNECTING 전환', () {
    testWidgets('call_accept 수신 → CONNECTING, 음성 채널은 session_start 까지 대기',
        (tester) async {
      final (sc, wm) = await pumpConnected(tester);
      await tester.tap(find.text('발신'));
      await tester.pump();
      sc.simulateIncomingMessage({'type': 'call_accept'});
      await pumpAsync(tester);
      expect(find.text('종료'), findsOneWidget);
      expect(relays, isEmpty);
      expect(wm.offerCreated, isFalse);
      expect(wm.initializeCallCount, 0);
    });
  });

  // ─────────────────────────────────────────────
  group('통화 음성 — 서버 경유 중계', () {
    testWidgets('발신자: session_start → 음성 채널 시작 + 통화 중', (tester) async {
      await pumpInCall(tester);
      expect(relays, hasLength(1));
      final r = relays.single;
      expect(r.startCount, 1);
      expect(r.role, 'caller');
      expect(r.sessionId, 's1');
      expect(r.url, Uri.parse('ws://test:8080/audio'));
      expect(find.text('Hang Up'), findsOneWidget);
      expect(find.textContaining('통화 중'), findsOneWidget);
    });

    testWidgets('수신자: 받기 → session_start(callee) → 통화 중', (tester) async {
      final (sc, _) = await pumpConnected(tester);
      sc.simulateIncomingMessage({'type': 'call_request'});
      await tester.pump();
      await tester.tap(find.text('받기'));
      await pumpAsync(tester);
      sc.simulateIncomingMessage(
          {'type': 'session_start', 'session_id': 's2', 'role': 'callee'});
      await pumpAsync(tester);
      expect(relays.single.role, 'callee');
      expect(relays.single.sessionId, 's2');
      expect(find.text('Hang Up'), findsOneWidget);
    });

    testWidgets('음성 채널 시작 실패 → hang_up 전송 + IDLE + 안내', (tester) async {
      failRelayStart = true;
      final (sc, _) = await pumpInCall(tester);
      expect(sc.sentMessages.any((m) => m['type'] == 'hang_up'), isTrue);
      expect(find.text('발신'), findsOneWidget);
      expect(find.textContaining('음성 채널 연결 실패'), findsOneWidget);
    });

    testWidgets('통화 중 1초 통계 → 통계 카드 표시', (tester) async {
      await pumpInCall(tester);
      relays.single.simulateStats(_stats);
      await tester.pump();
      expect(find.textContaining('Sent: +10 pkts'), findsOneWidget);
      expect(find.textContaining('Recv: +10 pkts'), findsOneWidget);
    });

    testWidgets('통화 중 음성 채널이 끊김 → hang_up 전송 + IDLE + 안내', (tester) async {
      final (sc, _) = await pumpInCall(tester);
      relays.single.simulateClosed('서버 종료');
      await tester.pump();
      expect(sc.sentMessages.any((m) => m['type'] == 'hang_up'), isTrue);
      expect(relays.single.stopCount, 1);
      expect(find.text('발신'), findsOneWidget);
      expect(find.textContaining('음성 채널이 끊겼습니다'), findsOneWidget);
    });

    testWidgets('통화 중에는 단독 보호 버튼(3초 녹음)이 막힌다', (tester) async {
      final (sc, _) = await pumpConnected(tester);
      TextButton protectButton() =>
          tester.widget<TextButton>(find.widgetWithText(TextButton, '시작'));
      expect(protectButton().onPressed, isNotNull);

      await tester.tap(find.text('발신'));
      await tester.pump();
      sc.simulateIncomingMessage({'type': 'call_accept'});
      await pumpAsync(tester);
      sc.simulateIncomingMessage(
          {'type': 'session_start', 'session_id': 's1', 'role': 'caller'});
      await pumpAsync(tester);
      expect(protectButton().onPressed, isNull);
    });
  });

  // ─────────────────────────────────────────────
  group('Bug #4 — stale 이벤트 무시', () {
    testWidgets('IDLE 상태에서 온 session_start 는 무시 (음성 채널 안 열림)',
        (tester) async {
      final (sc, _) = await pumpConnected(tester);
      sc.simulateIncomingMessage(
          {'type': 'session_start', 'session_id': 'stale', 'role': 'caller'});
      await pumpAsync(tester);
      expect(relays, isEmpty);
      expect(find.text('발신'), findsOneWidget);
    });

    testWidgets('WebRTC 메시지(offer/answer/ice)는 무시', (tester) async {
      final (sc, wm) = await pumpConnected(tester);
      sc.simulateIncomingMessage({'type': 'offer', 'sdp': 'v=0\r\nmock'});
      sc.simulateIncomingMessage({'type': 'answer', 'sdp': 'v=0\r\nmock'});
      sc.simulateIncomingMessage({
        'type': 'ice',
        'candidate': 'candidate:abc',
        'sdpMid': 'audio',
        'sdpMLineIndex': 0,
      });
      await pumpAsync(tester);
      expect(wm.lastRemoteSdp, isNull);
      expect(wm.answerCreated, isFalse);
      expect(find.text('발신'), findsOneWidget);
    });
  });

  // ─────────────────────────────────────────────
  group('통화 종료 흐름', () {
    testWidgets('IN_CALL 상태에서 Hang Up 버튼 표시', (tester) async {
      await pumpInCall(tester);
      expect(find.text('Hang Up'), findsOneWidget);
    });

    testWidgets('Hang Up 탭 → hang_up 전송 + 음성 채널 정지 + IDLE 복귀',
        (tester) async {
      final (sc, _) = await pumpInCall(tester);
      await tester.tap(find.text('Hang Up'));
      await tester.pump();
      expect(sc.sentMessages.any((m) => m['type'] == 'hang_up'), isTrue);
      expect(relays.single.stopCount, 1);
      expect(find.text('발신'), findsOneWidget);
    });

    testWidgets('상대방 hang_up 수신 → 음성 채널 정지 + IDLE 복귀 + "상대방 종료" 메시지',
        (tester) async {
      final (sc, _) = await pumpInCall(tester);
      sc.simulateIncomingMessage({'type': 'hang_up'});
      await tester.pump();
      expect(relays.single.stopCount, 1);
      expect(find.textContaining('상대방이 통화를 종료'), findsOneWidget);
      expect(find.text('발신'), findsOneWidget);
    });

    testWidgets('session_end 수신 → 음성 채널 정지 + IDLE 복귀', (tester) async {
      final (sc, _) = await pumpInCall(tester);
      sc.simulateIncomingMessage({
        'type': 'session_end',
        'session_id': 's1',
        'reason': 'peer_disconnected',
      });
      await tester.pump();
      expect(relays.single.stopCount, 1);
      expect(find.text('발신'), findsOneWidget);
    });

    testWidgets('hang_up 뒤에 오는 session_end 는 안내 문구를 덮지 않음',
        (tester) async {
      final (sc, _) = await pumpInCall(tester);
      sc.simulateIncomingMessage({'type': 'hang_up'});
      await tester.pump();
      sc.simulateIncomingMessage(
          {'type': 'session_end', 'session_id': 's1', 'reason': 'hang_up'});
      await tester.pump();
      expect(relays.single.stopCount, 1);
      expect(find.textContaining('상대방이 통화를 종료'), findsOneWidget);
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

    testWidgets('통화 중 시그널링 단절 → 음성 채널 정지', (tester) async {
      final (sc, _) = await pumpInCall(tester);
      sc.simulateDisconnect();
      await tester.pump();
      expect(relays.single.stopCount, 1);
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
  group('마이크 권한 거부', () {
    testWidgets('발신 시 권한 거부 → call_request 안 보냄 + IDLE + 안내', (tester) async {
      final sc = MockSignalingClient();
      final wm = MockWebRTCManager();
      await tester.pumpWidget(_buildTestApp(_makeScreen(
        signalingClient: sc,
        webRTCManager: wm,
        micGranted: false, // 거부
      )));
      await tester.pump();

      await tester.tap(find.text('발신'));
      await pumpAsync(tester);

      expect(sc.sentMessages.any((m) => m['type'] == 'call_request'), isFalse);
      expect(find.text('발신'), findsOneWidget);
      expect(find.textContaining('마이크 권한'), findsOneWidget);
    });

    testWidgets('수신 시 권한 거부 → call_reject 전송 + IDLE + 안내', (tester) async {
      final sc = MockSignalingClient();
      final wm = MockWebRTCManager();
      await tester.pumpWidget(_buildTestApp(_makeScreen(
        signalingClient: sc,
        webRTCManager: wm,
        micGranted: false, // 거부
      )));
      await tester.pump();
      sc.simulateIncomingMessage({'type': 'call_request'});
      await tester.pump();
      await tester.tap(find.text('받기'));
      await pumpAsync(tester);

      expect(sc.sentMessages.any((m) => m['type'] == 'call_accept'), isFalse);
      expect(sc.sentMessages.any((m) => m['type'] == 'call_reject'), isTrue);
      expect(find.text('발신'), findsOneWidget);
      expect(find.textContaining('마이크 권한'), findsOneWidget);
    });
  });
}
