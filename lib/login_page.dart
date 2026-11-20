import 'package:flutter/material.dart';

import 'api.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// Sign-in screen for the one account (set on the server).
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.api, required this.onSignedIn});

  final ApiClient api;
  final void Function(String token, DateTime expiresAt) onSignedIn;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _passFocus = FocusNode();
  bool _busy = false;
  bool _show = false;
  String? _error;

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    _passFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (_user.text.trim().isEmpty || _pass.text.isEmpty) {
      setState(() => _error = 'Enter your username and password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.api.login(_user.text.trim(), _pass.text);
      widget.onSignedIn(r.token, r.expiresAt);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  InputDecoration _field(String hint, {Widget? suffix}) => InputDecoration(
    hintText: hint,
    hintStyle: inter(size: 16, color: TC.placeholder),
    filled: true,
    fillColor: TC.surface,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    suffixIcon: suffix,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: const BorderSide(color: TC.border),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: const BorderSide(color: TC.border),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: const BorderSide(color: TC.accent),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TC.bg,
      body: Stack(
        children: [
          const Positioned(
            top: -70,
            right: -60,
            child: DriftCircle(size: 220, dashed: true),
          ),
          const Positioned(top: -20, right: -10, child: DriftCircle(size: 120)),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 400),
                  child: AutofillGroup(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Center(child: ThinkletLogo(size: 64)),
                        const SizedBox(height: 18),
                        Text(
                          'Welcome back',
                          textAlign: TextAlign.center,
                          style: grotesk(size: 28, spacing: -0.6),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Sign in to Thinklet',
                          textAlign: TextAlign.center,
                          style: inter(size: 15, color: TC.muted),
                        ),
                        const SizedBox(height: 28),
                        Semantics(
                          label: 'Username',
                          child: TextField(
                            controller: _user,
                            autofillHints: const [AutofillHints.username],
                            textInputAction: TextInputAction.next,
                            onSubmitted: (_) => _passFocus.requestFocus(),
                            style: inter(size: 16),
                            cursorColor: TC.accent,
                            decoration: _field('Username'),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Semantics(
                          label: 'Password',
                          child: TextField(
                            controller: _pass,
                            focusNode: _passFocus,
                            obscureText: !_show,
                            autofillHints: const [AutofillHints.password],
                            textInputAction: TextInputAction.go,
                            onSubmitted: (_) => _submit(),
                            style: inter(size: 16),
                            cursorColor: TC.accent,
                            decoration: _field(
                              'Password',
                              suffix: IconButton(
                                tooltip: _show
                                    ? 'Hide password'
                                    : 'Show password',
                                onPressed: () => setState(() => _show = !_show),
                                icon: Icon(
                                  _show
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                  size: 20,
                                  color: TC.muted,
                                ),
                              ),
                            ),
                          ),
                        ),
                        AnimatedSize(
                          duration: const Duration(milliseconds: 200),
                          child: _error == null
                              ? const SizedBox(width: double.infinity)
                              : Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: Semantics(
                                    liveRegion: true,
                                    child: Text(
                                      _error!,
                                      style: inter(
                                        size: 14,
                                        color: TC.dangerSoft,
                                      ),
                                    ),
                                  ),
                                ),
                        ),
                        const SizedBox(height: 20),
                        Pressable(
                          onTap: _submit,
                          label: 'Sign in',
                          radius: 16,
                          child: Container(
                            height: 50,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: TC.accent,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: _busy
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                      color: TC.bg,
                                    ),
                                  )
                                : Text(
                                    'Sign in',
                                    style: inter(
                                      size: 16,
                                      weight: FontWeight.w600,
                                      color: TC.bg,
                                    ),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
