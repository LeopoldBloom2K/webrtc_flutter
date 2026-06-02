import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'screens/call_main_screen.dart';

void main() {
  debugPrint('[APP] main() started — debug mode: $kDebugMode');
  runApp(const DeepVoiceApp());
}

class DeepVoiceApp extends StatelessWidget {
  const DeepVoiceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '딥보이스 보안 통화',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF2F2F7),
      ),
      home: const CallMainScreen(),
    );
  }
}
