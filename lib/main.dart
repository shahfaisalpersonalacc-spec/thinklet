import 'package:flutter/material.dart';

import 'home_page.dart';
import 'theme.dart';

void main() => runApp(const ThinkletApp());

class ThinkletApp extends StatelessWidget {
  const ThinkletApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Thinklet',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: TC.bg,
        colorScheme: ColorScheme.fromSeed(
          seedColor: TC.accent,
          brightness: Brightness.dark,
          primary: TC.accent,
          surface: TC.surface,
        ),
        textSelectionTheme: const TextSelectionThemeData(
          cursorColor: TC.accent,
          selectionColor: Color(0x55C6F24E),
          selectionHandleColor: TC.accent,
        ),
      ),
      home: const HomePage(),
    );
  }
}
