// 이 파일은 이전 counter-app 테스트를 대체한다.
// 실제 테스트는 test/unit/ 및 test/widget/ 하위 디렉터리에 있다.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webrtc_flutter/call_screen.dart';

import 'mocks/mock_signaling_client.dart';
import 'mocks/mock_webrtc_manager.dart';

void main() {
  testWidgets('앱 기본 smoke test — CallScreen이 에러 없이 렌더링됨',
      (WidgetTester tester) async {
    final sc = MockSignalingClient();
    final wm = MockWebRTCManager();

    await tester.pumpWidget(MaterialApp(
      home: CallScreen(
        signalingClient: sc,
        webRTCManager: wm,
        initialServerUrl: 'ws://localhost:8080',
        microphonePermissionChecker: () async => true,
      ),
    ));
    await tester.pump();

    expect(find.text('딥보이스 보안 통화'), findsOneWidget);
  });
}
