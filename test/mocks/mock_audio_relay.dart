import 'package:webrtc_flutter/audio_relay.dart';
import 'package:webrtc_flutter/webrtc_manager.dart' show AudioStats;

/// 테스트용 AudioRelay Mock.
/// 마이크·재생·소켓 없이 통화 흐름(시작·정지·끊김·통계)을 검증한다.
class MockAudioRelay extends AbstractAudioRelay {
  MockAudioRelay(this.url, this.sessionId, this.role, {this.failStart = false});

  final Uri url;
  final String sessionId;
  final String role;

  /// true 면 start() 가 실패한다 (서버 음성 채널 연결 실패 모의)
  final bool failStart;

  int startCount = 0;
  int stopCount = 0;

  @override
  Future<void> start() async {
    startCount++;
    if (failStart) throw StateError('mock: 음성 채널 연결 실패');
  }

  @override
  Future<void> stop() async {
    stopCount++;
  }

  /// 1초 통계가 들어온 것처럼 시뮬레이션한다.
  void simulateStats(AudioStats stats) => onStats?.call(stats);

  /// 통화 중 서버 음성 채널이 끊긴 것처럼 시뮬레이션한다.
  void simulateClosed(String reason) => onClosed?.call(reason);
}
