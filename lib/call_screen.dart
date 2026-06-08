import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/painting.dart' show FontFeature;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';

import 'signaling_client.dart';
import 'webrtc_manager.dart';
import 'vocalcrypt_service.dart';
import 'widgets/profile_circle.dart';

enum CallState { idle, calling, incomingCall, connecting, inCall }

class CallScreen extends StatefulWidget {
  const CallScreen({
    super.key,
    this.name = '',
    AbstractSignalingClient? signalingClient,
    AbstractWebRTCManager? webRTCManager,
    this.initialServerUrl = 'ws://10.0.2.2:8080',
    this.microphonePermissionChecker,
  })  : _signalingClient = signalingClient,
        _webRTCManager = webRTCManager;

  final String name;
  final AbstractSignalingClient? _signalingClient;
  final AbstractWebRTCManager? _webRTCManager;
  final String initialServerUrl;
  final Future<bool> Function()? microphonePermissionChecker;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen>
    with SingleTickerProviderStateMixin {
  late final AbstractSignalingClient _signalingClient;
  late final AbstractWebRTCManager _webRTCManager;
  late final AnimationController _waveController;
  late final TextEditingController _serverUrlController;
  late final TextEditingController _frequencyController;

  CallState _callState = CallState.idle;
  bool _serverConnected = false;
  String _statusMessage = '서버에 연결 중...';
  double _frequency = 440;
  Timer? _audioStatusTimer;
  AudioStats? _latestAudioStats;

  String _callDuration = '00:00';
  DateTime? _callStartTime;
  Timer? _callTimer;
  double _audioAmplitude = 0.0;

  // ── VocalCrypt 상태 ─────────────────────────────────────────────────────
  VocalCryptStatus _vcStatus = VocalCryptStatus.idle;
  String _vcMessage = '';

  bool get _isPowerOn => _callState == CallState.inCall;

  @override
  void initState() {
    super.initState();
    _signalingClient = widget._signalingClient ?? SignalingClient();

    // VocalCryptService를 주입한 WebRTCManager 생성
    _webRTCManager = widget._webRTCManager ?? WebRTCManager(
      vocalCryptService: VocalCryptService(
        serverUrl: 'http://10.0.2.2:8765',
        targetSnr: 22.0,
      ),
      vocalCryptEnabled: true,
    );

    _serverUrlController =
        TextEditingController(text: widget.initialServerUrl);
    _frequencyController = TextEditingController(text: '440');
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
    _setupSignalingCallbacks();
    _signalingClient.connect(_serverUrlController.text);
  }

  // ── 시그널링 콜백 ────────────────────────────────────────────────────────

  void _setupSignalingCallbacks() {
    _signalingClient.onConnected = () {
      if (!mounted) return;
      setState(() {
        _serverConnected = true;
        _statusMessage = '서버 연결됨. 대기 중...';
      });
    };

    _signalingClient.onDisconnected = () {
      if (!mounted) return;
      _webRTCManager.close();
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
        case 'offer':
          await _onOffer(message['sdp'] as String);
        case 'answer':
          await _onAnswer(message['sdp'] as String);
        case 'ice':
          await _onIce(message);
      }
    };
  }

  // ── WebRTC 콜백 ──────────────────────────────────────────────────────────

  void _setupWebRTCCallbacks() {
    _webRTCManager.onIceCandidate = (candidate) {
      _signalingClient.sendIce(
        candidate.candidate ?? '',
        candidate.sdpMid,
        candidate.sdpMLineIndex,
      );
    };

    _webRTCManager.onOfferCreated = (offer) {
      _signalingClient.sendOffer(offer.sdp!);
    };

    _webRTCManager.onAnswerCreated = (answer) {
      _signalingClient.sendAnswer(answer.sdp!);
    };

    _webRTCManager.onConnectionStateChange = (state) {
      if (!mounted) return;
      if (_callState == CallState.idle) return;
      setState(() {
        switch (state) {
          case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
            _callState = CallState.inCall;
            _statusMessage = '통화 중';
          case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
            _endCall(sendHangUp: false);
            _statusMessage = '연결이 끊겼습니다';
          default:
            break;
        }
      });
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _startAudioMonitor();
        _startCallTimer();
      }
    };

    _webRTCManager.onIceConnectionStateChange = (state) {
      if (!mounted) return;
      if (_callState == CallState.idle) return;
      switch (state) {
        case RTCIceConnectionState.RTCIceConnectionStateConnected:
        case RTCIceConnectionState.RTCIceConnectionStateCompleted:
          if (_callState == CallState.connecting) {
            setState(() {
              _callState = CallState.inCall;
              _statusMessage = '통화 중';
            });
            _startAudioMonitor();
            _startCallTimer();
          }
        case RTCIceConnectionState.RTCIceConnectionStateFailed:
          _endCall(sendHangUp: false);
          setState(() => _statusMessage = 'ICE 연결 실패');
        case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
          if (_callState == CallState.inCall) {
            _endCall(sendHangUp: false);
            setState(() => _statusMessage = '연결이 끊겼습니다');
          }
        default:
          break;
      }
    };

    _webRTCManager.onAudioStatsUpdate = (stats) {
      if (!mounted) return;
      final local = stats.micLevel.clamp(0.0, 1.0);
      final remote = (stats.receivedDelta / 55.0).clamp(0.0, 1.0);
      final level = local > 0.01 ? local : remote * 0.75;
      setState(() {
        _latestAudioStats = stats;
        _audioAmplitude = level;
      });
    };

    // VocalCrypt 상태 콜백
    _webRTCManager.onVocalCryptStatus = (status, message) {
      if (!mounted) return;
      setState(() {
        _vcStatus = status;
        _vcMessage = message;
      });
    };
  }

  // ── 발신 ────────────────────────────────────────────────────────────────

  void _startCall() {
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
    if (!mounted || _callState != CallState.calling) return;
    setState(() {
      _callState = CallState.connecting;
      _statusMessage = '연결 중...';
    });
    await _initWebRTC();
    if (!mounted) return;
    await _webRTCManager.createOffer();
  }

  void _onCallRejected() {
    if (!mounted) return;
    setState(() {
      _callState = CallState.idle;
      _statusMessage = '상대방이 거절했습니다';
    });
  }

  // ── 수신 ────────────────────────────────────────────────────────────────

  void _onCallRequest() {
    if (!mounted || _callState != CallState.idle) return;
    setState(() {
      _callState = CallState.incomingCall;
      _statusMessage = '전화가 왔습니다';
    });
  }

  Future<void> _acceptCall() async {
    setState(() {
      _callState = CallState.connecting;
      _statusMessage = '연결 중...';
    });
    _signalingClient.sendCallAccept();
    await _initWebRTC();
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

  // ── WebRTC 초기화 ────────────────────────────────────────────────────────

  Future<void> _initWebRTC() async {
    final bool granted;
    if (widget.microphonePermissionChecker != null) {
      granted = await widget.microphonePermissionChecker!();
    } else {
      final status = await Permission.microphone.request();
      granted = status.isGranted;
    }
    if (!granted) {
      if (!mounted) return;
      setState(() {
        _callState = CallState.idle;
        _statusMessage = '마이크 권한이 필요합니다';
      });
      return;
    }
    _setupWebRTCCallbacks();
    await _webRTCManager.initialize();
  }

  // ── SDP / ICE ────────────────────────────────────────────────────────────

  Future<void> _onOffer(String sdp) async {
    if (_callState != CallState.connecting) return;
    await _webRTCManager.setRemoteDescription(sdp, 'offer');
    await _webRTCManager.createAnswer();
  }

  Future<void> _onAnswer(String sdp) async {
    await _webRTCManager.setRemoteDescription(sdp, 'answer');
  }

  Future<void> _onIce(Map<String, dynamic> message) async {
    final candidate = message['candidate'] as String?;
    if (candidate == null) return;
    await _webRTCManager.addIceCandidate(
      candidate,
      message['sdpMid'] as String?,
      message['sdpMLineIndex'] as int?,
    );
  }

  // ── 타이머 / 모니터링 ─────────────────────────────────────────────────────

  void _startCallTimer() {
    _callStartTime = DateTime.now();
    _callTimer?.cancel();
    _callTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) { _callTimer?.cancel(); return; }
      final d = DateTime.now().difference(_callStartTime!);
      final h = d.inHours;
      final m = (d.inMinutes % 60).toString().padLeft(2, '0');
      final s = (d.inSeconds % 60).toString().padLeft(2, '0');
      setState(() => _callDuration = h > 0 ? '$h:$m:$s' : '$m:$s');
    });
  }

  void _startAudioMonitor() {
    _audioStatusTimer?.cancel();
    _audioStatusTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted) { _audioStatusTimer?.cancel(); return; }
      final s = _webRTCManager.getAudioStatus();
      debugPrint('[Audio] Local:${s.localActive} Remote:${s.remoteActive}');
    });
  }

  // ── 통화 종료 ────────────────────────────────────────────────────────────

  void _hangUp() => _endCall(sendHangUp: true);

  void _onRemoteHangUp() {
    if (!mounted) return;
    _endCall(sendHangUp: false);
    setState(() => _statusMessage = '상대방이 통화를 종료했습니다');
  }

  void _endCall({required bool sendHangUp}) {
    _audioStatusTimer?.cancel();
    _audioStatusTimer = null;
    _callTimer?.cancel();
    _callTimer = null;
    if (sendHangUp) _signalingClient.sendHangUp();
    _webRTCManager.close();
    if (!mounted) return;
    setState(() {
      _callState = CallState.idle;
      _statusMessage = '통화 종료됨';
      _latestAudioStats = null;
      _callDuration = '00:00';
      _audioAmplitude = 0.0;
      _vcStatus = VocalCryptStatus.idle;
      _vcMessage = '';
    });
  }

  // ── VocalCrypt 보호 실행 ─────────────────────────────────────────────────

  Future<void> _runVocalCrypt() async {
    final result = await _webRTCManager.captureAndProtect(durationSeconds: 3);
    if (result == null && mounted) {
      setState(() {
        _vcStatus = VocalCryptStatus.error;
        _vcMessage = 'VocalCrypt를 지원하지 않는 환경입니다';
      });
    }
  }

  @override
  void dispose() {
    _audioStatusTimer?.cancel();
    _callTimer?.cancel();
    _signalingClient.disconnect();
    _webRTCManager.close();
    _serverUrlController.dispose();
    _frequencyController.dispose();
    _waveController.dispose();
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
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _buildServerCard(),
              const SizedBox(height: 16),
              // ── VocalCrypt 보호 카드 ──────────────────────────────────
              _buildVocalCryptCard(),
              const SizedBox(height: 20),
              const ProfileCircle(),
              if (widget.name.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  widget.name,
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF111111),
                  ),
                ),
              ],
              const SizedBox(height: 10),
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
                    width: 16, height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2, color: Color(0xFF8E8E93),
                    ),
                  ),
                ),
              const SizedBox(height: 24),
              _buildWaveContainer(),
              const SizedBox(height: 12),
              _buildFrequencyInput(),
              if (_callState == CallState.inCall && _latestAudioStats != null) ...[
                const SizedBox(height: 12),
                _buildAudioStatsCard(_latestAudioStats!),
              ],
              const SizedBox(height: 24),
              _buildCallControls(),
            ],
          ),
        ),
      ),
    );
  }

  // ── VocalCrypt 카드 위젯 ─────────────────────────────────────────────────

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

    final bool isRunning = _vcStatus == VocalCryptStatus.recording ||
        _vcStatus == VocalCryptStatus.processing;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.35)),
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
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: color.withOpacity(0.12),
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
                if (_vcMessage.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    _vcMessage,
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xFF8E8E93)),
                  ),
                ] else ...[
                  const SizedBox(height: 2),
                  Text(
                    _vcStatus == VocalCryptStatus.idle
                        ? '통화 전 음성을 보호하세요'
                        : _vcStatus == VocalCryptStatus.done
                        ? '음성 보호 완료'
                        : '',
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xFF8E8E93)),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (isRunning)
            SizedBox(
              width: 20, height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: color),
            )
          else
            TextButton(
              onPressed: _serverConnected ? _runVocalCrypt : null,
              style: TextButton.styleFrom(
                foregroundColor: color,
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 6),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                _vcStatus == VocalCryptStatus.done ? '재보호' : '시작',
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600, color: color),
              ),
            ),
        ],
      ),
    );
  }

  // ── 기존 위젯들 (변경 없음) ───────────────────────────────────────────────

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
                      color: Color(0xFF111111), fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'ws://10.0.2.2:8080',
                    hintStyle: const TextStyle(color: Color(0xFFB8B8B8)),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8)),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide:
                      const BorderSide(color: Color(0xFFE0E0E0)),
                    ),
                    disabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide:
                      const BorderSide(color: Color(0xFFE0E0E0)),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _serverConnected
                    ? null
                    : () => _signalingClient
                    .connect(_serverUrlController.text),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF111111),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: const Color(0xFF34C759),
                  disabledForegroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
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

  Widget _buildWaveContainer() {
    return Container(
      width: double.infinity,
      height: 120,
      decoration: BoxDecoration(
        color: const Color(0xFFF8F8F8),
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Color.fromRGBO(0, 0, 0, 0.06),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: AnimatedBuilder(
          animation: _waveController,
          builder: (context, _) => CustomPaint(
            painter: _WavePainter(
              isPowerOn: _isPowerOn,
              frequency: _frequency,
              phase: _waveController.value * math.pi * 2,
              audioLevel: _audioAmplitude,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFrequencyInput() {
    return Container(
      width: 160,
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
            color: Color.fromRGBO(0, 0, 0, 0.06),
            blurRadius: 8,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: TextField(
        controller: _frequencyController,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        onChanged: (value) {
          final f = double.tryParse(value);
          if (f != null) setState(() => _frequency = f);
        },
        decoration: const InputDecoration(
          border: InputBorder.none,
          suffixText: 'Hz',
          isDense: true,
          contentPadding: EdgeInsets.symmetric(vertical: 10),
        ),
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
        return _callButton(
          label: 'Hang Up',
          icon: Icons.call_end,
          color: const Color(0xFFFF3B30),
          onPressed: _hangUp,
        );
    }
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
              color: txOk
                  ? const Color(0xFF34C759)
                  : const Color(0xFFFF9500),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '🔊 ${stats.speakerActive ? "ACTIVE" : "SILENT"}  📥 Recv: +${stats.receivedDelta} pkts  +${stats.bytesReceivedDelta} B',
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: rxOk
                  ? const Color(0xFF34C759)
                  : const Color(0xFFFF3B30),
            ),
          ),
          if (stats.isStalled) ...[
            const SizedBox(height: 4),
            const Text(
              '⚠️  STALL: 패킷 미흐름 — 마이크 권한/ICE 확인',
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
              borderRadius: BorderRadius.circular(28)),
          elevation: 0,
        ),
      ),
    );
  }
}

// ── WavePainter (변경 없음) ──────────────────────────────────────────────────

class _WavePainter extends CustomPainter {
  const _WavePainter({
    required this.isPowerOn,
    required this.frequency,
    required this.phase,
    this.audioLevel = 0.0,
  });

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
        final y = size.height / 2 +
            math.sin((x / size.width) * math.pi * idleWaveCount) *
                idleAmplitude;
        x == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
    } else {
      final waveCount = (frequency / 100).clamp(2.0, 12.0);
      final amplitude = 8.0 + audioLevel * 34.0;
      for (double x = 0; x <= size.width; x++) {
        final y = size.height / 2 +
            math.sin((x / size.width) * math.pi * waveCount + phase) *
                amplitude;
        x == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
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