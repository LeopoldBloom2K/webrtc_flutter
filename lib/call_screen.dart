import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';

import 'signaling_client.dart';
import 'webrtc_manager.dart';

// Bug #1: 수신/발신 대기 상태 포함한 완전한 상태머신
enum CallState { idle, calling, incomingCall, connecting, inCall }

class CallScreen extends StatefulWidget {
  const CallScreen({
    super.key,
    AbstractSignalingClient? signalingClient,
    AbstractWebRTCManager? webRTCManager,
    this.initialServerUrl = 'ws://10.0.2.2:8080',
    this.microphonePermissionChecker,
  })  : _signalingClient = signalingClient,
        _webRTCManager = webRTCManager;

  final AbstractSignalingClient? _signalingClient;
  final AbstractWebRTCManager? _webRTCManager;
  final String initialServerUrl;

  /// 테스트에서 permission_handler 플러그인 없이 권한 결과를 주입한다.
  /// null이면 실제 Permission.microphone.request()를 사용한다.
  final Future<bool> Function()? microphonePermissionChecker;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  late final AbstractSignalingClient _signalingClient;
  late final AbstractWebRTCManager _webRTCManager;

  CallState _callState = CallState.idle;
  bool _serverConnected = false;
  String _statusMessage = '서버에 연결 중...';

  late final TextEditingController _serverUrlController;

  @override
  void initState() {
    super.initState();
    _signalingClient = widget._signalingClient ?? SignalingClient();
    _webRTCManager = widget._webRTCManager ?? WebRTCManager();
    _serverUrlController =
        TextEditingController(text: widget.initialServerUrl);
    _setupSignalingCallbacks();
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

  // ── WebRTC 콜백 설정 ────────────────────────────────────────────────────

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
      // Bug #4: endCall() 이후 IDLE 상태라면 stale 콜백 무시
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
    };
  }

  // ── 발신 흐름 ───────────────────────────────────────────────────────────

  // Bug #1: CALLING 상태 + call_request 전송
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
    // Bug #6: call_accept 수신 시 먼저 CONNECTING으로 전환 후 offer 생성
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

  // ── SDP / ICE 수신 ──────────────────────────────────────────────────────

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

  // ── 통화 종료 ────────────────────────────────────────────────────────────

  void _hangUp() => _endCall(sendHangUp: true);

  void _onRemoteHangUp() {
    if (!mounted) return;
    _endCall(sendHangUp: false);
    // setState는 _endCall 내부에서 호출하므로 추가 setState 없이 덮어쓰기
    setState(() => _statusMessage = '상대방이 통화를 종료했습니다');
  }

  void _endCall({required bool sendHangUp}) {
    if (sendHangUp) _signalingClient.sendHangUp();
    _webRTCManager.close(); // Bug #2/#3: isClosed 플래그 선행 세팅 + 올바른 해제 순서
    if (!mounted) return;
    setState(() {
      _callState = CallState.idle; // Bug #4: IDLE로 전환해 stale 콜백 차단
      _statusMessage = '통화 종료됨';
    });
  }

  @override
  void dispose() {
    // Bug #5: intentionalDisconnect = true → onDisconnected 억제
    _signalingClient.disconnect();
    _webRTCManager.close(); // isClosed 중복 호출 안전 처리됨
    _serverUrlController.dispose();
    super.dispose();
  }

  // ── UI ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF16213E),
        foregroundColor: Colors.white,
        title: const Text('딥보이스 보안 통화'),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            _buildServerCard(),
            const SizedBox(height: 32),
            Expanded(child: _buildStatusSection()),
            _buildCallControls(),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildServerCard() {
    return Card(
      color: const Color(0xFF16213E),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '시그널링 서버',
              style: TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _serverUrlController,
                    enabled: !_serverConnected,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'ws://10.0.2.2:8080',
                      hintStyle: const TextStyle(color: Colors.white38),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8)),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Colors.white24),
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
                    backgroundColor: _serverConnected
                        ? Colors.green.shade800
                        : Colors.indigo,
                    foregroundColor: Colors.white,
                  ),
                  child: Text(_serverConnected ? '연결됨' : '연결'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusSection() {
    final iconData = _callState == CallState.inCall
        ? Icons.phone_in_talk
        : _callState == CallState.incomingCall
            ? Icons.phone_callback
            : Icons.phone;

    final iconColor = _callState == CallState.inCall
        ? Colors.greenAccent
        : _callState == CallState.incomingCall
            ? Colors.amberAccent
            : Colors.white38;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(iconData, size: 96, color: iconColor),
        const SizedBox(height: 24),
        if (_callState == CallState.calling ||
            _callState == CallState.connecting)
          const Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: CircularProgressIndicator(color: Colors.indigoAccent),
          ),
        Text(
          _statusMessage,
          style: const TextStyle(
              color: Colors.white, fontSize: 18, fontWeight: FontWeight.w500),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildCallControls() {
    switch (_callState) {
      case CallState.idle:
        return _serverConnected
            ? _callButton(
                label: '발신',
                icon: Icons.phone,
                color: Colors.green,
                onPressed: _startCall,
              )
            : Text(
                '서버에 연결 후 통화할 수 있습니다',
                style: TextStyle(color: Colors.white38),
              );

      case CallState.calling:
        return _callButton(
          label: '취소',
          icon: Icons.call_end,
          color: Colors.orange,
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
              color: Colors.red,
              onPressed: _rejectCall,
              width: 140,
            ),
            _callButton(
              label: '받기',
              icon: Icons.phone,
              color: Colors.green,
              onPressed: _acceptCall,
              width: 140,
            ),
          ],
        );

      case CallState.connecting:
        return const Text(
          'WebRTC 연결 협상 중...',
          style: TextStyle(color: Colors.white54),
        );

      case CallState.inCall:
        // Bug #1: Hang Up 버튼
        return _callButton(
          label: 'Hang Up',
          icon: Icons.call_end,
          color: Colors.red,
          onPressed: _hangUp,
        );
    }
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
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        ),
      ),
    );
  }
}
