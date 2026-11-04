import 'package:flutter/material.dart';

import 'screens/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BlueskyMutualApp());
}

class BlueskyMutualApp extends StatelessWidget {
  const BlueskyMutualApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bluesky 相互チェッカー',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF0085FF),
        fontFamily: 'Segoe UI',
        fontFamilyFallback: const ['Yu Gothic UI', 'Meiryo'],
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF0085FF),
        fontFamily: 'Segoe UI',
        fontFamilyFallback: const ['Yu Gothic UI', 'Meiryo'],
      ),
      home: const HomeScreen(),
    );
  }
}
