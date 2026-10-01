import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/painting.dart' show FontFeature;
import 'package:permission_handler/permission_handler.dart';

import 'audio_relay.dart';
import 'signaling_client.dart';
import 'webrtc_manager.dart';
import 'vocalcrypt_service.dart';
import 'widgets/profile_circle.dart';

// Bug #1: 수신/발신 대기 상태 포함한 완전한 상태머신
enum CallState { idle, calling, incomingCall, connecting, inCall }

class CallScreen extends StatefulWidget {
  const CallScreen({
    super.key,
    this.name = '',
    AbstractSignalingClient? signalingClient,
    AbstractWebRTCManager? webRTCManager,
    this.initialServerUrl = 'ws://10.0.2.2:8080',
    this.microphonePermissionChecker,
    this.audioRelayFactory,
  }) : _signalingClient = signalingClient,
       _webRTCManager = webRTCManager;

  final String name;
  final AbstractSignalingClient? _signalingClient;
  final AbstractWebRTCManager? _webRTCManager;
  final String initialServerUrl;

  /// 테스트에서 permission_handler 플러그인 없이 권한 결과를 주입한다.
  /// null이면 실제 Permission.microphone.request()를 사용한다.
  final Future<bool> Function()? microphonePermissionChecker;

  /// 테스트에서 마이크·재생·소켓 없이 통화 흐름을 검증하도록 음성 중계를 주입한다.
  /// null 이면 실제 [AudioRelay] 를 쓴다.
  final AbstractAudioRelay Function(Uri url, String sessionId, String role)?
      audioRelayFactory;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  late final AbstractSignalingClient _signalingClient;
  late final AbstractWebRTCManager _webRTCManager;
  late final TextEditingController _serverUrlController;

  CallState _callState = CallState.idle;

  // VocalCrypt 상태
  VocalCryptStatus _vcStatus = VocalCryptStatus.idle;
  String _vcMessage = '';
  bool _serverConnected = false;
  String _statusMessage = '서버에 연결 중...';
  AudioStats? _latestAudioStats;

  // 통화 음성 중계. session_start 에서 만들고 통화가 끝나면 정지한다.
  AbstractAudioRelay? _relay;

  String _callDuration = '00:00';
  DateTime? _callStartTime;
  Timer? _callTimer;
  // 통화 중일 때만 파형 활성화
  @override
  void initState() {
    super.initState();
    _signalingClient = widget._signalingClient ?? SignalingClient();
    _webRTCManager =
        widget._webRTCManager ??
        WebRTCManager(
          vocalCryptService: VocalCryptService(
            serverUrl: 'http://10.0.2.2:8080',
            targetSnr: 22.0,
          ),
          vocalCryptEnabled: true,
        );
    _serverUrlController = TextEditingController(text: widget.initialServerUrl);
    _setupSignalingCallbacks();

    // VocalCrypt 상태 콜백
    _webRTCManager.onVocalCryptStatus = (status, message) {
      if (!mounted) return;
      setState(() {
        _vcStatus = status;
        _vcMessage = message;
      });
    };

    _signalingClient.connect(_serverUrlController.text);
  }

  // ── 시그널링 콜백 설정 ──────────────────────────────────────────────────

  void _setupSignalingCallbacks() {
    _signalingClient.onConnected = () {
      if (!mounted) return;
      setState(() {
        _serverConnected = true;
        _statusMessage = '서버 연결됨. 대기 중...';
      });
    };

    // Bug #5 대응: SignalingClient 내부의 intentionalDisconnect 플래그가
    //   dispose() 시점 콜백을 억제하므로, 여기서는 mounted 체크만 추가.
    _signalingClient.onDisconnected = () {
      if (!mounted) return;
      _stopRelay();
      setState(() {
        _serverConnected = false;
        _callState = CallState.idle;
        _statusMessage = '서버 연결 끊김';
      });
    };

    _signalingClient.onMessage = (message) async {
      if (!mounted) return;
      switch (message['type'] as String?) {
        case 'call_request':
          _onCallRequest();
        case 'call_accept':
          await _onCallAccepted();
        case 'call_reject':
          _onCallRejected();
        case 'call_cancel':
          _onCallCancelled();
        case 'hang_up':
          _onRemoteHangUp();
        case 'session_start':
          await _onSessionStart(message);
        case 'session_end':
          _onSessionEnd();
      }
    };
  }

  // ── VocalCrypt 보호 실행 ─────────────────────────────────────────────────

  // 16kHz / 48kHz 비교 측정 모드. 측정이 끝나면 false 로 되돌린다.
  // true 면 보호 버튼이 두 샘플레이트를 차례로 녹음·보호하고 결과를 비교한다.
  static const bool kCompareSampleRates = true;

  Future<void> _runVocalCrypt() async {
    if (kCompareSampleRates) {
      await _runSampleRateComparison();
      return;
    }
    final result = await _webRTCManager.captureAndProtect(durationSeconds: 3);
    if (result == null && mounted) {
      setState(() {
        _vcStatus = VocalCryptStatus.error;
        _vcMessage = 'VocalCrypt를 지원하지 않는 환경입니다';
      });
    }
  }

  /// 같은 마이크로 16kHz 와 48kHz 를 차례로 녹음해 보호 결과를 비교한다.
  /// 상세 수치는 logcat 의 [VocalCrypt/비교] 줄에 남는다.
  Future<void> _runSampleRateComparison() async {
    final results =
        await _webRTCManager.compareSampleRates(durationSeconds: 3);
    if (!mounted) return;
    if (results.isEmpty) {
      setState(() {
        _vcStatus = VocalCryptStatus.error;
        _vcMessage = 'VocalCrypt를 지원하지 않는 환경입니다';
      });
      return;
    }
    final parts = <String>[];
    for (final entry in results.entries) {
      final r = entry.value;
      if (r == null || !r.success) {
        parts.add('${entry.key}Hz 실패(${r?.errorMessage ?? '-'})');
      } else {
        parts.add('${entry.key}Hz '
            'SNR ${r.serverSnrDb?.toStringAsFixed(1) ?? '-'}dB '
            '서버 ${r.serverProcessingMs?.toStringAsFixed(0) ?? '-'}ms '
            '왕복 ${r.processingTimeMs?.toStringAsFixed(0) ?? '-'}ms');
      }
    }
    setState(() {
      _vcStatus = VocalCryptStatus.done;
      _vcMessage = parts.join('\n');
    });
  }

  // ── 발신 흐름 ───────────────────────────────────────────────────────────

  // Bug #1: CALLING 상태 + call_request 전송
  Future<void> _startCall() async {
    // 마이크 권한은 걸기 전에 확인한다. 상대가 받으면 곧바로 음성 채널을 연다.
    if (!await _ensureMicPermission()) return;
    if (!mounted || _callState != CallState.idle) return;
    setState(() {
      _callState = CallState.calling;
      _statusMessage = '전화 거는 중...';
    });
    _signalingClient.sendCallRequest();
  }

  void _cancelCall() {
    _signalingClient.sendCallCancel();
    setState(() {
      _callState = CallState.idle;
      _statusMessage = '통화 취소됨';
    });
  }

  Future<void> _onCallAccepted() async {
    // Bug #6: call_accept 수신 시 먼저 CONNECTING으로 전환.
    // 음성 채널은 서버가 바로 뒤이어 보내는 session_start 에서 연다.
    if (!mounted || _callState != CallState.calling) return;
    setState(() {
      _callState = CallState.connecting;
      _statusMessage = '연결 중...';
    });
  }

  void _onCallRejected() {
    if (!mounted) return;
    setState(() {
      _callState = CallState.idle;
      _statusMessage = '상대방이 거절했습니다';
    });
  }

  // ── 수신 흐름 ───────────────────────────────────────────────────────────

  // Bug #1: INCOMING_CALL 상태 UI 진입
  void _onCallRequest() {
    if (!mounted || _callState != CallState.idle) return;
    setState(() {
      _callState = CallState.incomingCall;
      _statusMessage = '전화가 왔습니다';
    });
  }

  Future<void> _acceptCall() async {
    // 권한을 먼저 확인한다. call_accept 를 보내면 서버가 곧바로 session_start 를
    // 보내고, 그때 마이크를 연다. 거부하면 발신자가 기다리지 않도록 거절을 보낸다.
    if (!await _ensureMicPermission()) {
      _signalingClient.sendCallReject();
      return;
    }
    if (!mounted || _callState != CallState.incomingCall) return;
    setState(() {
      _callState = CallState.connecting;
      _statusMessage = '연결 중...';
    });
    _signalingClient.sendCallAccept();
  }

  void _rejectCall() {
    _signalingClient.sendCallReject();
    setState(() {
      _callState = CallState.idle;
      _statusMessage = '통화 거절됨';
    });
  }

  void _onCallCancelled() {
    if (!mounted) return;
    setState(() {
      _callState = CallState.idle;
      _statusMessage = '상대방이 취소했습니다';
    });
  }

  // ── 마이크 권한 ──────────────────────────────────────────────────────────

  /// 거부되면 IDLE 로 되돌리고 안내한다.
  Future<bool> _ensureMicPermission() async {
    final bool granted;
    if (widget.microphonePermissionChecker != null) {
      granted = await widget.microphonePermissionChecker!();
    } else {
      final status = await Permission.microphone.request();
      granted = status.isGranted;
    }
    if (!granted && mounted) {
      setState(() {
        _callState = CallState.idle;
        _statusMessage = '마이크 권한이 필요합니다';
      });
    }
    return granted;
  }

  // ── 통화 음성 (서버 경유) ────────────────────────────────────────────────
  //
  //   내 마이크 → 서버(VocalCrypt) → 상대 스피커,  상대 마이크 → 서버 → 내 스피커
  //   상대가 듣는 소리는 언제나 서버에서 보호된 음성이다.

  Future<void> _onSessionStart(Map<String, dynamic> message) async {
    final sessionId = message['session_id'] as String?;
    final role = message['role'] as String?;
    if (_callState != CallState.connecting || _relay != null) return;
    if (sessionId == null || role == null) return;

    final url = Uri.parse(_serverUrlController.text).replace(path: '/audio');
    final relay = widget.audioRelayFactory?.call(url, sessionId, role) ??
        AudioRelay(url: url, sessionId: sessionId, role: role);
    relay.onStats = (stats) {
      if (!mounted || _relay != relay) return;
      setState(() => _latestAudioStats = stats);
    };
    relay.onClosed = (reason) {
      if (!mounted || _relay != relay) return;
      debugPrint('[Relay] 통화 중 끊김: $reason');
      _endCall(sendHangUp: true);
      setState(() => _statusMessage = '음성 채널이 끊겼습니다');
    };
    _relay = relay;

    try {
      await relay.start();
    } catch (e) {
      debugPrint('[Relay] 시작 실패: $e');
      if (_relay != relay) return; // 시작하는 사이에 통화가 이미 끝남
      _endCall(sendHangUp: true);
      if (mounted) setState(() => _statusMessage = '음성 채널 연결 실패');
      return;
    }
    if (!mounted || _relay != relay) return;
    setState(() {
      _callState = CallState.inCall;
      _statusMessage = '통화 중';
    });
    _startCallTimer();
  }

  void _onSessionEnd() {
    if (!mounted || _callState == CallState.idle) return;
    _endCall(sendHangUp: false);
  }

  void _stopRelay() {
    final relay = _relay;
    _relay = null;
    if (relay != null) unawaited(relay.stop());
  }

  // ── 통화 타이머 ──────────────────────────────────────────────────────────

  void _startCallTimer() {
    _callStartTime = DateTime.now();
    _callTimer?.cancel();
    _callTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        _callTimer?.cancel();
        return;
      }
      final d = DateTime.now().difference(_callStartTime!);
      final h = d.inHours;
      final m = (d.inMinutes % 60).toString().padLeft(2, '0');
      final s = (d.inSeconds % 60).toString().padLeft(2, '0');
      setState(() => _callDuration = h > 0 ? '$h:$m:$s' : '$m:$s');
    });
  }

  // ── 통화 종료 ────────────────────────────────────────────────────────────

  void _hangUp() => _endCall(sendHangUp: true);

  void _onRemoteHangUp() {
    if (!mounted) return;
    _endCall(sendHangUp: false);
    // setState는 _endCall 내부에서 호출하므로 추가 setState 없이 덮어쓰기
    setState(() => _statusMessage = '상대방이 통화를 종료했습니다');
  }

  void _endCall({required bool sendHangUp}) {
    _callTimer?.cancel();
    _callTimer = null;
    if (sendHangUp) _signalingClient.sendHangUp();
    _stopRelay();
    if (!mounted) return;
    setState(() {
      _callState = CallState.idle;
      _statusMessage = '통화 종료됨';
      _latestAudioStats = null;
      _callDuration = '00:00';
    });
  }

  @override
  void dispose() {
    _callTimer?.cancel();
    _stopRelay();
    _signalingClient.disconnect();
    _webRTCManager.close(); // isClosed 중복 호출 안전 처리됨
    _serverUrlController.dispose();
    super.dispose();
  }

  // ── UI ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF2F2F7),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: const Color(0xFF111111),
        title: const Text(
          '딥보이스 보안 통화',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 32, 20, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // ── 1. 프로필 + 이름 ─────────────────────────
              const ProfileCircle(),
              const SizedBox(height: 16),
              if (widget.name.isNotEmpty)
                Text(
                  widget.name,
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF111111),
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                _statusMessage,
                style: const TextStyle(fontSize: 15, color: Color(0xFF8E8E93)),
                textAlign: TextAlign.center,
              ),
              if (_callState == CallState.inCall) ...[
                const SizedBox(height: 6),
                Text(
                  _callDuration,
                  style: const TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w200,
                    color: Color(0xFF111111),
                    letterSpacing: 4,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
              if (_callState == CallState.calling ||
                  _callState == CallState.connecting)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFF8E8E93),
                    ),
                  ),
                ),
              const SizedBox(height: 32),
              // ── 2. 시그널링 서버 카드 ──────────────────────
              _buildServerCard(),
              const SizedBox(height: 12),
              // ── 3. 딥보이스 보호 카드 ──────────────────────
              _buildVocalCryptCard(),
              const SizedBox(height: 100),
              // ── 4. 발신/수신/종료 버튼 ─────────────────────
              _buildCallControls(),
              if (_callState == CallState.inCall &&
                  _latestAudioStats != null) ...[
                const SizedBox(height: 16),
                _buildAudioStatsCard(_latestAudioStats!),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildServerCard() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(
            color: Color.fromRGBO(0, 0, 0, 0.06),
            blurRadius: 10,
            offset: Offset(0, 3),
          ),
        ],
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '시그널링 서버',
            style: TextStyle(
              color: Color(0xFF8E8E93),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _serverUrlController,
                  enabled: !_serverConnected,
                  style: const TextStyle(
                    color: Color(0xFF111111),
                    fontSize: 13,
                  ),
                  decoration: InputDecoration(
                    hintText: 'ws://10.0.2.2:8080',
                    hintStyle: const TextStyle(color: Color(0xFFB8B8B8)),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFFE0E0E0)),
                    ),
                    disabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFFE0E0E0)),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _serverConnected
                    ? null
                    : () => _signalingClient.connect(_serverUrlController.text),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF111111),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: const Color(0xFF34C759),
                  disabledForegroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  elevation: 0,
                ),
                child: Text(_serverConnected ? '연결됨' : '연결'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCallControls() {
    switch (_callState) {
      case CallState.idle:
        return _serverConnected
            ? _callButton(
                label: '발신',
                icon: Icons.phone,
                color: const Color(0xFF34C759),
                onPressed: _startCall,
              )
            : const Text(
                '서버에 연결 후 통화할 수 있습니다',
                style: TextStyle(color: Color(0xFF8E8E93)),
              );

      case CallState.calling:
        return _callButton(
          label: '취소',
          icon: Icons.call_end,
          color: const Color(0xFFFF9500),
          onPressed: _cancelCall,
        );

      case CallState.incomingCall:
        // Bug #1: 수신 UI — 받기 / 거절
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _callButton(
              label: '거절',
              icon: Icons.call_end,
              color: const Color(0xFFFF3B30),
              onPressed: _rejectCall,
              width: 140,
            ),
            _callButton(
              label: '받기',
              icon: Icons.phone,
              color: const Color(0xFF34C759),
              onPressed: _acceptCall,
              width: 140,
            ),
          ],
        );

      case CallState.connecting:
        return _callButton(
          label: '종료',
          icon: Icons.call_end,
          color: const Color(0xFFFF3B30),
          onPressed: _hangUp,
        );

      case CallState.inCall:
        // Bug #1: Hang Up 버튼
        return _callButton(
          label: 'Hang Up',
          icon: Icons.call_end,
          color: const Color(0xFFFF3B30),
          onPressed: _hangUp,
        );
    }
  }

  // ── VocalCrypt 카드 ─────────────────────────────────────────────────────
  Widget _buildVocalCryptCard() {
    final Color color;
    final Color bgColor;
    final IconData icon;

    switch (_vcStatus) {
      case VocalCryptStatus.idle:
        color = const Color(0xFF8E8E93);
        bgColor = Colors.white;
        icon = Icons.shield_outlined;
      case VocalCryptStatus.recording:
        color = const Color(0xFFFF9500);
        bgColor = const Color(0xFFFFF8EE);
        icon = Icons.mic;
      case VocalCryptStatus.processing:
        color = const Color(0xFF007AFF);
        bgColor = const Color(0xFFEFF6FF);
        icon = Icons.sync;
      case VocalCryptStatus.done:
        color = const Color(0xFF34C759);
        bgColor = const Color(0xFFF0FFF4);
        icon = Icons.verified_user;
      case VocalCryptStatus.error:
        color = const Color(0xFFFF3B30);
        bgColor = const Color(0xFFFFF0EF);
        icon = Icons.error_outline;
    }

    final bool isRunning =
        _vcStatus == VocalCryptStatus.recording ||
        _vcStatus == VocalCryptStatus.processing;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        boxShadow: const [
          BoxShadow(
            color: Color.fromRGBO(0, 0, 0, 0.05),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      '딥보이스 보호',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF111111),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        _vcStatus.name.toUpperCase(),
                        style: TextStyle(
                          fontSize: 9,
                          color: color,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  _vcMessage.isNotEmpty
                      ? _vcMessage
                      : _vcStatus == VocalCryptStatus.idle
                      ? '통화 전 음성을 보호하세요'
                      : _vcStatus == VocalCryptStatus.done
                      ? '음성 보호 완료'
                      : '',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF8E8E93),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (isRunning)
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: color),
            )
          else
            TextButton(
              // 통화 중에는 음성 중계가 마이크를 쓰고 있으므로 막는다.
              onPressed: _serverConnected && _relay == null
                  ? _runVocalCrypt
                  : null,
              style: TextButton.styleFrom(
                foregroundColor: color,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                _vcStatus == VocalCryptStatus.done ? '재보호' : '시작',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _serverConnected && _relay == null
                      ? color
                      : const Color(0xFFB8B8B8),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAudioStatsCard(AudioStats stats) {
    final txOk = stats.sentDelta > 0;
    final rxOk = stats.speakerActive;
    final borderColor = stats.isStalled
        ? const Color(0xFFFF3B30)
        : (txOk || rxOk)
        ? const Color(0xFF34C759)
        : const Color(0xFFFF9500);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '🎤 Mic: ${stats.micLevel.toStringAsFixed(4)}  📤 Sent: +${stats.sentDelta} pkts',
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: txOk ? const Color(0xFF34C759) : const Color(0xFFFF9500),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '🔊 ${stats.speakerActive ? "ACTIVE" : "SILENT"}  📥 Recv: +${stats.receivedDelta} pkts  +${stats.bytesReceivedDelta} B',
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: rxOk ? const Color(0xFF34C759) : const Color(0xFFFF3B30),
            ),
          ),
          if (stats.isStalled) ...[
            const SizedBox(height: 4),
            const Text(
              '⚠️  STALL: 패킷 미흐름 — 마이크 권한/서버 음성 채널 확인',
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: Color(0xFFFF3B30),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _callButton({
    required String label,
    required IconData icon,
    required Color color,
    required VoidCallback onPressed,
    double width = 200,
  }) {
    return SizedBox(
      width: width,
      height: 56,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon),
        label: Text(label, style: const TextStyle(fontSize: 16)),
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          elevation: 0,
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  const _WavePainter({
    required this.isPowerOn,
    required this.frequency,
    required this.phase,
  }) : audioLevel = 0.0;

  final bool isPowerOn;
  final double frequency;
  final double phase;
  final double audioLevel;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = isPowerOn ? Colors.black : const Color(0xFFC7C7CC)
      ..strokeWidth = isPowerOn ? 3 : 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final path = Path();

    if (!isPowerOn) {
      const idleAmplitude = 8.0;
      const idleWaveCount = 3.0;
      for (double x = 0; x <= size.width; x++) {
        final y =
            size.height / 2 +
            math.sin((x / size.width) * math.pi * idleWaveCount) *
                idleAmplitude;
        if (x == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
    } else {
      final waveCount = (frequency / 100).clamp(2.0, 12.0);
      // audioLevel=0 → 8px(무음), audioLevel=1 → 42px(최대)
      final amplitude = 8.0 + audioLevel * 34.0;

      for (double x = 0; x <= size.width; x++) {
        final y =
            size.height / 2 +
            math.sin((x / size.width) * math.pi * waveCount + phase) *
                amplitude;
        if (x == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _WavePainter oldDelegate) =>
      oldDelegate.isPowerOn != isPowerOn ||
      oldDelegate.frequency != frequency ||
      oldDelegate.phase != phase ||
      oldDelegate.audioLevel != audioLevel;
}
