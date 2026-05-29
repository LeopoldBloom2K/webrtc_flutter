import 'package:flutter/material.dart';

import 'call_screen.dart';

void main() {
  runApp(const DeepVoiceApp());
}

class DeepVoiceApp extends StatelessWidget {
  const DeepVoiceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '딥보이스 보안 통화',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        colorScheme: ColorScheme.dark(
          primary: Colors.indigoAccent,
          secondary: Colors.cyanAccent,
        ),
      ),
      home: const CallScreen(),
    );
  }
}
