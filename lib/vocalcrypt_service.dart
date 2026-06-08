// lib/vocalcrypt_service.dart
//
// VocalCrypt 서비스: 음성 파일을 서버에 전송하여 노이즈 처리 후 반환받는다.
// Flutter WebRTC 앱에서 통화 전 레퍼런스 오디오를 보호할 때 사용한다.
//
// 사용 흐름:
//   1. 사용자 마이크에서 짧은 음성 샘플 녹음
//   2. VocalCryptService.protect() 로 서버에 전송
//   3. 보호된 WAV를 받아서 화자 클로닝 방어에 활용

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class VocalCryptResult {
  final bool success;
  final Uint8List? protectedAudio; // 처리된 WAV 바이트
  final String? errorMessage;
  final double? processingTimeMs;

  const VocalCryptResult({
    required this.success,
    this.protectedAudio,
    this.errorMessage,
    this.processingTimeMs,
  });
}

class VocalCryptService {
  final String serverUrl;
  final double targetSnr;

  const VocalCryptService({
    this.serverUrl = 'http://10.0.2.2:8765', // Android 에뮬레이터 → 로컬호스트
    this.targetSnr = 22.0,
  });

  /// 서버 생존 확인
  Future<bool> isServerAlive() async {
    try {
      final resp = await http
          .get(Uri.parse('$serverUrl/health'))
          .timeout(const Duration(seconds: 3));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// WAV 파일을 VocalCrypt 서버로 전송하여 보호된 오디오 반환
  ///
  /// [wavBytes] : 처리할 WAV 파일의 바이트 배열
  /// [targetSnr]: 목표 SNR (dB), 높을수록 음질 보존, 낮을수록 방어 강화
  Future<VocalCryptResult> protect(
      Uint8List wavBytes, {
        double? targetSnr,
      }) async {
    final startTime = DateTime.now();
    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$serverUrl/protect'),
      );

      request.files.add(http.MultipartFile.fromBytes(
        'file',
        wavBytes,
        filename: 'audio.wav',
      ));
      request.fields['target_snr'] = (targetSnr ?? this.targetSnr).toString();

      final streamedResponse = await request.send().timeout(
        const Duration(seconds: 30), // 최대 30초 대기
      );
      final response = await http.Response.fromStream(streamedResponse);

      final elapsed = DateTime.now().difference(startTime).inMilliseconds;

      if (response.statusCode == 200) {
        return VocalCryptResult(
          success: true,
          protectedAudio: response.bodyBytes,
          processingTimeMs: elapsed.toDouble(),
        );
      } else {
        return VocalCryptResult(
          success: false,
          errorMessage: 'Server error ${response.statusCode}: ${response.body}',
        );
      }
    } on SocketException {
      return const VocalCryptResult(
        success: false,
        errorMessage: 'VocalCrypt 서버에 연결할 수 없습니다',
      );
    } on TimeoutException {
      return const VocalCryptResult(
        success: false,
        errorMessage: 'VocalCrypt 서버 응답 시간 초과',
      );
    } catch (e) {
      return VocalCryptResult(
        success: false,
        errorMessage: '처리 오류: $e',
      );
    }
  }

  /// 처리된 오디오를 임시 파일로 저장하고 경로 반환
  Future<String?> saveProtectedAudio(Uint8List wavBytes) async {
    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/protected_${DateTime.now().millisecondsSinceEpoch}.wav';
      await File(path).writeAsBytes(wavBytes);
      return path;
    } catch (_) {
      return null;
    }
  }
}