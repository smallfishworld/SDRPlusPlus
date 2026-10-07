import 'package:flutter/material.dart';
import 'screens/receiver_screen.dart';
import 'theme/app_theme.dart';

void main() {
  runApp(const SdrppApp());
}

class SdrppApp extends StatelessWidget {
  const SdrppApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SDR++',
      theme: AppTheme.dark(),
      home: const ReceiverScreen(),
    );
  }
}
