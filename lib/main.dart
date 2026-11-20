import 'package:flutter/material.dart';

import 'api.dart';
import 'home_page.dart';
import 'login_page.dart';
import 'theme.dart';

/// Backend address, e.g. "/api" (hosted web) or "https://…vercel.app/api".
/// Empty: no backend (tests / old direct-key builds), no login.
const _apiBase = String.fromEnvironment('API_BASE');

void main() => runApp(const ThinkletApp());

class ThinkletApp extends StatelessWidget {
  const ThinkletApp({super.key, this.api});

  /// Injected in tests; otherwise built from API_BASE.
  final ApiClient? api;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Thinklet',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: TC.bg,
        fontFamily: 'Inter',
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
      home: _AuthGate(
        api: api ?? (_apiBase.isEmpty ? null : ApiClient(base: _apiBase)),
      ),
    );
  }
}

/// Shows the login screen until signed in, then the app. With no backend
/// configured, goes straight to the app.
class _AuthGate extends StatefulWidget {
  const _AuthGate({required this.api});
  final ApiClient? api;

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  bool _checking = true;
  bool _signedIn = false;
  String _draft = ''; // typed text kept across a sign-in expiry
  AppTab _tab = AppTab.write; // reopened where the user left off

  @override
  void initState() {
    super.initState();
    final api = widget.api;
    if (api == null) {
      _checking = false;
      return;
    }
    // Sign-in and last tab load together, so the app opens on the right
    // tab with no flash of the other one.
    Future.wait([
      api.token != null ? Future.value(api.token) : Session.load(),
      Session.loadTab(),
    ]).then((r) {
      if (!mounted) return;
      setState(() {
        api.token = r[0];
        _signedIn = r[0] != null;
        _tab = r[1] == AppTab.notes.name ? AppTab.notes : AppTab.write;
        _checking = false;
      });
    });
  }

  void _onSignedIn(String token, DateTime expiresAt) {
    Session.save(token, expiresAt);
    setState(() => _signedIn = true);
  }

  void _signOut(String draft) {
    Session.clear();
    widget.api?.token = null;
    setState(() {
      _draft = draft;
      _signedIn = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final api = widget.api;
    if (api == null) return const HomePage();
    if (_checking) return const Scaffold(backgroundColor: TC.bg);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      child: _signedIn
          ? HomePage(
              key: const ValueKey('home'),
              api: api,
              initialText: _draft,
              initialTab: _tab,
              onTabChanged: (t) {
                _tab = t;
                Session.saveTab(t.name);
              },
              onSignOut: _signOut,
            )
          : LoginPage(
              key: const ValueKey('login'),
              api: api,
              onSignedIn: _onSignedIn,
            ),
    );
  }
}
