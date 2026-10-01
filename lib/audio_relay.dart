// lib/audio_relay.dart
//
// 서버 경유 통화 음성 중계.
//
//   내 마이크 ─PCM16 100ms─▶ ws /audio ─(서버: VocalCrypt)─▶ 상대방 스피커
//   상대 마이크 ─PCM16 100ms─▶ ws /audio ─(서버: VocalCrypt)─▶ 내 스피커
//
// 상대가 듣는 소리는 서버에서 보호된 음성이다. 통화 음성은 WebRTC 를 거치지 않는다.
// 프로토콜은 server/audio.py 에 있다.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart'
    show FlutterPcmSound, LogLevel, PcmArrayInt16;
import 'package:record/record.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'webrtc_manager.dart' show AudioStats;

/// 테스트에서 Mock 으로 바꿀 수 있도록 인터페이스를 분리한다.
abstract class AbstractAudioRelay {
  /// 1초마다 송수신 통계. 통화 화면의 통계 카드에 그대로 쓴다.
  void Function(AudioStats stats)? onStats;

  /// 통화 중에 서버 채널이 끊겼을 때. stop() 으로 끊은 경우에는 부르지 않는다.
  void Function(String reason)? onClosed;

  /// 재생 준비 → 서버 채널 연결·핸드셰이크 → 마이크 송신 시작.
  /// 실패하면 열어둔 자원을 정리하고 예외를 던진다.
  Future<void> start();

  /// 여러 번 불러도 안전하다. start() 도중에 불러도 된다.
  Future<void> stop();
}

class AudioRelay extends AbstractAudioRelay {
  AudioRelay({
    required this.url,
    required this.sessionId,
    required this.role,
    this.sampleRate = 16000,
    this.frameMs = 100,
    this.targetSnr = 22.0,
  });

  /// ws://host:8080/audio
  final Uri url;
  final String sessionId;

  /// caller | callee — 서버가 session_start 로 알려준 값
  final String role;
  final int sampleRate;

  /// 서버가 VocalCrypt 를 한 번에 적용하는 단위. 짧을수록 지연은 줄지만 청크 경계
  /// 불연속이 커진다(경계 점프가 20ms 에서 청크 내부의 5.5배, 100ms 에서 2.4배).
  final int frameMs;
  final double targetSnr;

  @override
  void Function(AudioStats stats)? onStats;
  @override
  void Function(String reason)? onClosed;

  WebSocketChannel? _ch;
  StreamSubscription<dynamic>? _wsSub;
  AudioRecorder? _rec;
  StreamSubscription<Uint8List>? _micSub;
  Timer? _statsTimer;
  bool _playerReady = false;
  bool _stopped = false;

  /// 프레임 길이에 못 미쳐 다음 마이크 조각과 합칠 바이트
  Uint8List _carry = Uint8List(0);

  int _sent = 0, _received = 0, _receivedBytes = 0;
  int _prevSent = 0, _prevReceived = 0, _prevReceivedBytes = 0;
  int _idleTicks = 0;
  double _micSq = 0;
  int _micN = 0, _micPeak = 0;
  int _queuedFrames = 0;

  int get _frameBytes => sampleRate * frameMs ~/ 1000 * 2;

  void _checkStopped() {
    if (_stopped) throw StateError('중계가 시작 도중에 정지됨');
  }

  @override
  Future<void> start() async {
    try {
      // 1) 재생기를 먼저 준비한다. 상대가 이미 말하고 있으면 audio_ready 직후에
      //    음성이 도착한다.
      await FlutterPcmSound.setLogLevel(LogLevel.error); // feed 마다 찍히는 로그 끔
      await FlutterPcmSound.setup(sampleRate: sampleRate, channelCount: 1);
      _playerReady = true;
      _checkStopped();
      await FlutterPcmSound.setFeedThreshold(sampleRate); // 1초 이하로 남으면 알림
      FlutterPcmSound.setFeedCallback((remaining) => _queuedFrames = remaining);

      // 2) 서버 채널과 핸드셰이크. 실패 사유는 값으로 받아서, 기다리기 전에
      //    실패해도 처리되지 않은 예외가 되지 않게 한다. null 이면 성공.
      final ready = Completer<String?>();
      final ch = WebSocketChannel.connect(url);
      _ch = ch;
      _wsSub = ch.stream.listen(
        (data) => _onServer(data, ready),
        onDone: () => _onServerClosed(
          ready,
          '서버가 음성 채널을 닫음 (${ch.closeCode ?? '-'} ${ch.closeReason ?? ''})',
        ),
        onError: (Object e) => _onServerClosed(ready, '음성 채널 오류: $e'),
        cancelOnError: true,
      );
      await ch.ready.timeout(const Duration(seconds: 5));
      _checkStopped();
      ch.sink.add(jsonEncode({
        'session_id': sessionId,
        'role': role,
        'sample_rate': sampleRate,
        'target_snr': targetSnr,
      }));
      final failure = await ready.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => 'audio_ready 응답 없음',
      );
      if (failure != null) throw StateError(failure);
      _checkStopped();

      // 3) 마이크. audioInterruption 을 none 으로 두어야 오디오 포커스를 요청하지
      //    않는다. 기본값(pause)이면 포커스 변화에 녹음이 멈춘다.
      final rec = AudioRecorder();
      _rec = rec;
      final mic = await rec.startStream(RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
        echoCancel: true,
        audioInterruption: AudioInterruptionMode.none,
      ));
      _checkStopped();
      _micSub = mic.listen(
        _onMic,
        onError: (Object e) => debugPrint('[Relay] 마이크 오류: $e'),
      );

      _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
      debugPrint('[Relay] $role 시작  $url  ${sampleRate}Hz  ${frameMs}ms 프레임');
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    _statsTimer?.cancel();
    _statsTimer = null;

    // 자원은 꺼낸 뒤 null 로 비운다. start() 도중에 불려도 그 뒤에 생긴 자원은
    // start() 의 catch 가 다시 부르는 stop() 이 정리한다.
    final micSub = _micSub, rec = _rec, ch = _ch, wsSub = _wsSub;
    final player = _playerReady;
    _micSub = null;
    _rec = null;
    _ch = null;
    _wsSub = null;
    _playerReady = false;
    if (micSub == null && rec == null && ch == null && wsSub == null && !player) {
      return;
    }

    try {
      await micSub?.cancel();
    } catch (_) {}
    try {
      await rec?.stop();
      await rec?.dispose();
    } catch (_) {}
    try {
      await ch?.sink.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
    try {
      await wsSub?.cancel();
    } catch (_) {}
    if (player) {
      try {
        FlutterPcmSound.setFeedCallback(null);
        await FlutterPcmSound.release();
      } catch (_) {}
    }
    debugPrint('[Relay] $role 종료  송신 $_sent / 수신 $_received 프레임');
  }

  void _onServer(dynamic data, Completer<String?> ready) {
    if (data is String) {
      // 서버가 보내는 텍스트는 핸드셰이크 응답뿐이다.
      try {
        final msg = jsonDecode(data);
        if (msg is Map && msg['type'] == 'audio_ready' && !ready.isCompleted) {
          ready.complete(null);
        }
      } catch (_) {}
      return;
    }
    if (_stopped || data is! List<int>) return;
    // 재생기는 넘겨받은 ByteData 의 버퍼 전체를 보내므로, 이 프레임만 담은
    // 새 버퍼로 복사해서 넘긴다.
    final bytes = Uint8List.fromList(data);
    _received++;
    _receivedBytes += bytes.length;
    unawaited(_feed(bytes));
  }

  Future<void> _feed(Uint8List bytes) async {
    try {
      await FlutterPcmSound.feed(PcmArrayInt16(bytes: bytes.buffer.asByteData()));
    } catch (e) {
      debugPrint('[Relay] 재생 오류: $e');
    }
  }

  void _onServerClosed(Completer<String?> ready, String reason) {
    if (!ready.isCompleted) {
      ready.complete(reason); // 핸드셰이크 중 실패 → start() 가 예외로 바꾼다
      return;
    }
    if (_stopped) return;
    debugPrint('[Relay] $reason');
    onClosed?.call(reason);
  }

  void _onMic(Uint8List data) {
    if (_stopped || data.isEmpty) return;
    _measure(data);

    final Uint8List buf;
    if (_carry.isEmpty) {
      buf = data;
    } else {
      buf = Uint8List(_carry.length + data.length)
        ..setRange(0, _carry.length, _carry)
        ..setRange(_carry.length, _carry.length + data.length, data);
    }
    final fb = _frameBytes;
    var off = 0;
    while (buf.length - off >= fb) {
      _ch?.sink.add(Uint8List.sublistView(buf, off, off + fb));
      _sent++;
      off += fb;
    }
    _carry = Uint8List.fromList(Uint8List.sublistView(buf, off));
  }

  /// 마이크 절대 레벨. peak 와 RMS 의 차이(crest factor)가 3~4dB 면 목소리가
  /// 아니라 연속 톤이 들어오고 있는 것이다(정상 음성은 15dB 이상).
  void _measure(Uint8List data) {
    final bd = ByteData.sublistView(data);
    for (var i = 0; i + 1 < data.length; i += 2) {
      final s = bd.getInt16(i, Endian.little);
      _micSq += s * s;
      final a = s.abs();
      if (a > _micPeak) _micPeak = a;
    }
    _micN += data.length ~/ 2;
  }

  void _tick() {
    final sent = _sent - _prevSent;
    final recv = _received - _prevReceived;
    final bytes = _receivedBytes - _prevReceivedBytes;
    _prevSent = _sent;
    _prevReceived = _received;
    _prevReceivedBytes = _receivedBytes;
    _idleTicks = (sent == 0 && recv == 0) ? _idleTicks + 1 : 0;

    final rms = _micN > 0 ? math.sqrt(_micSq / _micN) / 32768.0 : 0.0;
    final peak = _micPeak / 32768.0;
    _micSq = 0;
    _micN = 0;
    _micPeak = 0;

    debugPrint(
      '[Relay] $role  송신 +$sent / 수신 +$recv 프레임  '
      '마이크 RMS ${_dbfs(rms)} / peak ${_dbfs(peak)} dBFS  '
      '재생 대기 ${_queuedFrames * 1000 ~/ sampleRate}ms',
    );
    onStats?.call(AudioStats(
      micLevel: rms,
      sentDelta: sent,
      receivedDelta: recv,
      bytesReceivedDelta: bytes,
      speakerActive: recv > 0,
      isStalled: _idleTicks >= 3,
    ));
  }

  static String _dbfs(double x) =>
      x > 0 ? (20.0 * math.log(x) / math.ln10).toStringAsFixed(1) : '-inf';
}
