# WebRTC 음성통화 앱 — Troubleshooting 기록

초기 코드에서 발견된 버그들과 수정 과정을 시간 순서대로 정리한 문서입니다.

---

## 버그 #1: 수신 UI 및 통화 제어 로직 부재

### 증상
- 한 기기에서 Start Call을 눌러도 상대 기기에 아무런 UI가 나타나지 않음
- 통화를 종료할 방법이 없음 (Hang Up 버튼 없음)
- 발신자가 즉시 WebRTC offer를 생성해 상대방 동의 없이 연결을 강제함

### 원인
초기 코드의 `CallState`가 `IDLE / CONNECTING / CONNECTED / IN_CALL` 4가지뿐이었고, 시그널링 메시지 타입도 `offer / answer / ice`만 존재했습니다. 수신 대기(`INCOMING_CALL`)와 발신 대기(`CALLING`) 상태, 그리고 그에 해당하는 제어 메시지(`call_request / call_accept / call_reject / call_cancel`)가 전혀 구현되어 있지 않았습니다.

### 수정
**`MainActivity.kt`** — `CallState` enum에 두 상태 추가:
```kotlin
// Before
enum class CallState { IDLE, CONNECTING, CONNECTED, IN_CALL }

// After
enum class CallState { IDLE, CONNECTING, CONNECTED, INCOMING_CALL, CALLING, IN_CALL }
```

**`SignalingClient.kt`** — 제어 메시지 송수신 추가:
```kotlin
fun sendCallRequest() = send(JSONObject().put("type", "call_request"))
fun sendCallAccept()  = send(JSONObject().put("type", "call_accept"))
fun sendCallReject()  = send(JSONObject().put("type", "call_reject"))
fun sendCallCancel()  = send(JSONObject().put("type", "call_cancel"))
```

**`CallScreen` Composable** — 상태별 UI 분기 추가:
- `INCOMING_CALL`: "전화 받기" / "거절" 버튼
- `CALLING`: 스피너 + "취소" 버튼
- `IN_CALL`: 빨간 "Hang Up" 버튼
- `CONNECTED`: "Start Call (발신)" + "Disconnect" 버튼

**통화 흐름 확정:**
```
A: Start Call → call_request →
B: 수신 UI → 전화 받기 → call_accept →
A: offer 생성 → offer/answer/ice 교환 → 양쪽 IN_CALL
```

---

## 버그 #2: Hang Up 시 SIGSEGV 크래시 (WebRTC 네이티브 메모리 오류)

### 증상
- 통화 종료(Hang Up) 버튼을 누르면 앱이 즉시 강제 종료됨
- Android tombstone에 `signal 11 (SIGSEGV)` 기록
- 크래시 위치: `libjingle_peerconnection_so.so` 내부

### 원인
`WebRTCManager.close()`에서 WebRTC 네이티브 객체 해제 순서가 잘못되어 있었습니다.

**초기 코드의 잘못된 해제 순서:**
```kotlin
// WRONG — factory를 먼저 dispose하면 자식 객체들이 dangling pointer 상태가 됨
peerConnectionFactory.dispose()  // ← 먼저 해제
peerConnection?.close()
localAudioTrack?.dispose()       // ← factory 해제 후 접근 → SIGSEGV
```

추가로:
- `peerConnection.dispose()` 호출 누락 → JNI 메모리 미해제
- `localAudioTrack`이 `lateinit var`로 선언되어 null 체크 불가
- `audioSource`를 멤버 변수로 보관하지 않아 dispose 불가

### 수정
**`WebRTCManager.kt`** — 올바른 해제 순서 적용:
```kotlin
// CORRECT — 자식 → 부모 순서
peerConnection?.close()
peerConnection?.dispose()   // JNI 메모리 해제 (필수)
peerConnection = null

localAudioTrack?.setEnabled(false)
localAudioTrack?.dispose()
localAudioTrack = null

audioSource?.dispose()      // AudioTrack 이후 해제
audioSource = null

peerConnectionFactory.dispose()  // 마지막에 factory 해제
```

멤버 변수 타입 변경:
```kotlin
// Before
private lateinit var localAudioTrack: AudioTrack

// After
private var localAudioTrack: AudioTrack? = null
private var audioSource: AudioSource? = null
```

---

## 버그 #3: dispose 후 네이티브 SDP 객체 접근 (use-after-free)

### 증상
- `close()` 호출 직후 비동기 SDP 콜백이 발화해 이미 해제된 네이티브 객체에 접근
- 간헐적 크래시 또는 예측 불가능한 동작

### 원인
`sdpObserver`의 `onCreateSuccess()` 콜백은 WebRTC 네이티브 스레드에서 비동기로 발화합니다. `close()`가 이미 모든 네이티브 객체를 해제한 뒤에도 이 콜백이 호출될 수 있었습니다.

### 수정
`@Volatile private var isClosed = false` 플래그 추가 후, 모든 비동기 진입점에 가드 삽입:
```kotlin
private fun sdpObserver(tag: String, onSuccess: (SessionDescription) -> Unit = {}): SdpObserver =
    object : SdpObserver {
        override fun onCreateSuccess(sdp: SessionDescription) {
            if (isClosed) {  // ← 가드 추가
                Log.d(TAG, "$tag: skipping SDP callback — already closed")
                return
            }
            onSuccess(sdp)
        }
        // ...
    }

fun createOffer() {
    if (isClosed) return  // ← 공개 메서드도 가드
    peerConnection?.createOffer(sdpObserver("createOffer") { sdp ->
        if (isClosed) return@sdpObserver  // ← 람다 내부도 가드
        // ...
    }, MediaConstraints())
}
```

`close()` 시작 시 플래그를 가장 먼저 세팅:
```kotlin
fun close() {
    if (isClosed) return
    isClosed = true  // ← 선행 세팅으로 이후 콜백 차단
    // ... 나머지 해제 로직
}
```

---

## 버그 #4: endCall() 이후 stale WebRTC 콜백이 UI를 덮어씌움

### 증상
- Hang Up 후 상태 메시지가 "통화 종료"로 표시되다가 잠시 뒤 "상대방이 통화를 종료했습니다"로 바뀜
- 또는 IDLE 상태에서 갑자기 다른 메시지로 변경됨

### 원인
`PeerConnectionObserver`의 `onConnectionStateChange`는 WebRTC 내부 스레드에서 비동기로 발화합니다. `endCall()`이 `callState = IDLE`로 전환한 뒤에도, 큐에 쌓여 있던 `runOnUiThread { }` 블록이 뒤늦게 실행되어 상태 메시지를 덮어썼습니다.

### 수정
```kotlin
onConnectionStateChange = { state: PeerConnection.PeerConnectionState ->
    runOnUiThread {
        // endCall()이 이미 IDLE로 전환한 경우 stale 콜백 무시
        if (callState == CallState.IDLE) return@runOnUiThread
        when (state) {
            PeerConnection.PeerConnectionState.CONNECTED -> { /* ... */ }
            PeerConnection.PeerConnectionState.DISCONNECTED,
            PeerConnection.PeerConnectionState.FAILED -> { /* ... */ }
            else -> {}
        }
    }
}
```

---

## 버그 #5: signalingClient.disconnect() 후 onDisconnected가 "통화 종료" 메시지를 덮어씌움

### 증상
- Hang Up 후 "통화 종료" 메시지가 표시되었다가 "서버 연결 끊김"으로 바뀜
- UX가 혼란스럽고 최종 상태가 의도와 다름

### 원인
`SignalingClient.disconnect()`가 `webSocket?.close(1000, "Call ended")`를 호출하면, OkHttp가 비동기로 `WebSocketListener.onClosed()`를 발화하고, 이 안에서 `onDisconnected()` 콜백이 실행됩니다. `endCall()`이 "통화 종료"를 먼저 세팅해도, 이 지연 콜백이 "서버 연결 끊김"으로 덮어썼습니다.

### 수정
`@Volatile private var intentionalDisconnect = false` 플래그 도입:
```kotlin
fun disconnect() {
    intentionalDisconnect = true        // ← 의도적 종료 표시
    webSocket?.close(1000, "Call ended")
    webSocket = null
}

override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
    if (!intentionalDisconnect) onDisconnected()  // ← 의도적 종료면 콜백 억제
    intentionalDisconnect = false
}

override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
    if (!intentionalDisconnect) onDisconnected()
    intentionalDisconnect = false
}
```

---

## 버그 #6: call_accept 수신 후 CALLING 상태가 유지되는 문제

### 증상
- 수신자가 "전화 받기"를 눌러도 발신자 화면이 스피너(CALLING)에서 변화 없음
- WebRTC offer는 생성되지만 UI가 CONNECTING으로 전환되지 않음

### 원인
`onCallAccepted` 콜백에서 `callState` 전환 없이 바로 `webRTCManager.createOffer()`를 호출했습니다.

### 수정
```kotlin
onCallAccepted = {
    runOnUiThread {
        callState = CallState.CONNECTING  // ← 상태 전환 추가
        statusMessage = "연결 중..."
    }
    webRTCManager.createOffer()
},
```

---

## 버그 #7: 통화 중 SIGABRT 크래시 (network_thread, 38~128초 후 발생)

### 증상
- 통화 연결 성공 후 30초~2분 사이에 앱이 강제 종료됨
- Android tombstone에 `signal 6 (SIGABRT)`, 스레드 이름 `network_thread`
- 크래시 위치: `libjingle_peerconnection_so.so` → `sdk/android/src/jni/jvm.cc:81`
- 직전 logcat에 `android.hardware.audio@7.1-impl.ranchu: 544 frames of silence written` 메시지 수백 개

### 원인 분석
tombstone의 logcat 섹션에서 결정적인 스택 트레이스 발견:
```
W System.err: at ConnectivityService.enforceAccessPermission(...)
W System.err: at ConnectivityService.getActiveNetworkInfo(...)
E rtc     : # Fatal error in: ../../../sdk/android/src/jni/jvm.cc, line 81
E rtc     : # Check failed: false
```

**원인:** WebRTC의 `network_thread`는 네트워크 상태 변경을 감지하기 위해 주기적으로 `ConnectivityManager.getActiveNetworkInfo()`를 호출합니다. 이 API는 `ACCESS_NETWORK_STATE` 권한을 요구하는데, `AndroidManifest.xml`에 해당 권한이 선언되어 있지 않았습니다.

**크래시 전파 경로:**
```
network_thread 주기적 호출
  → ConnectivityManager.getActiveNetworkInfo()
  → ContextImpl.enforceCallingOrSelfPermission()  ← 권한 없음
  → SecurityException 발생
  → JNI jvm.cc:81 에서 예외 감지 → RTC_CHECK(false)
  → abort() → SIGABRT
```

오디오 HAL "silence written" 메시지가 logcat 버퍼를 가득 채워 실제 CHECK 메시지가 처음에는 보이지 않았습니다.

### 수정
**`AndroidManifest.xml`** — 권한 한 줄 추가:
```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />  <!-- 추가 -->
```

### 검증
수정 후 3분간 통화 유지 테스트에서 크래시 없음 확인. Hang Up 시 양측 상태 정상 전환 확인.

---

## 최종 권한 목록 (`AndroidManifest.xml`)

| 권한 | 용도 |
|------|------|
| `INTERNET` | WebSocket 서버 연결, WebRTC STUN/DTLS |
| `RECORD_AUDIO` | 마이크 입력 (runtime permission 요청) |
| `MODIFY_AUDIO_SETTINGS` | `AudioManager.MODE_IN_COMMUNICATION` 전환 |
| `ACCESS_NETWORK_STATE` | WebRTC network_thread의 네트워크 상태 감시 |

---

## 수정 파일 요약

| 파일 | 변경 내용 |
|------|-----------|
| `AndroidManifest.xml` | `ACCESS_NETWORK_STATE` 권한 추가 |
| `MainActivity.kt` | `CallState` enum 확장, 수신/발신/종료 UI 및 로직 전면 구현, stale 콜백 가드 추가 |
| `SignalingClient.kt` | 통화 제어 메시지 송수신 추가, `intentionalDisconnect` 플래그 추가 |
| `WebRTCManager.kt` | 올바른 객체 해제 순서 적용, `isClosed` 가드 전면 추가, nullable 멤버 변수로 전환 |