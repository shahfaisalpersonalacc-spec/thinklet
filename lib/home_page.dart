import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import 'claude_service.dart';
import 'diff.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// Build-time key from .env: flutter run --dart-define-from-file=.env
const _apiKey = String.fromEnvironment('ANTHROPIC_API_KEY');
const _noKeyMessage =
    'No API key. Add ANTHROPIC_API_KEY to .env and run with '
    '--dart-define-from-file=.env';

/// History button hidden for now; history is still recorded behind it.
const _historyEnabled = false;

enum Mode { correct, translate }

enum Phase { idle, checking, done }

class Lang {
  const Lang(this.name, {this.rtl = false});
  final String name;
  final bool rtl;
}

const languages = [
  Lang('English'),
  Lang('Urdu', rtl: true),
  Lang('Hindi'),
  Lang('Arabic', rtl: true),
  Lang('Spanish'),
  Lang('French'),
  Lang('German'),
  Lang('Chinese'),
  Lang('Japanese'),
  Lang('Turkish'),
];

bool _isRtl(String name) => languages.any((l) => l.name == name && l.rtl);

class Tone {
  const Tone(this.name, this.guide);
  final String name;
  final String guide;
}

const tones = [
  Tone('Formal', 'polished and formal, suitable for official letters.'),
  Tone(
    'Professional',
    'clear, confident and businesslike, suitable for work emails.',
  ),
  Tone(
    'Friendly',
    'warm and approachable, like writing to a colleague you like.',
  ),
  Tone('Casual', 'relaxed and conversational, like a message to a friend.'),
  Tone('Concise', 'as short as possible while keeping every key fact.'),
];

class HistoryEntry {
  HistoryEntry(this.id, this.kind, this.before, this.after, this.at);
  final String id;
  final String kind; // "Corrected", a tone name, or a language name
  final String before;
  final String after;
  final DateTime at;
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.claude});

  /// Injected in tests; the app builds its own from the .env key.
  final ClaudeService? claude;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  final _input = TextEditingController();
  // Phone: swipe position between the text (0) and the result (1). Shared by
  // the card pager and the indicator under it, so both move with the finger.
  late final AnimationController _swipe;
  bool _swipedOnce = false; // until then, hint that the cards can be swiped
  int _peek = 0; // bumped to make the pager peek at the text once
  late final ClaudeService _claude =
      widget.claude ?? ClaudeService(apiKey: _apiKey);
  bool get _noKey => widget.claude == null && _apiKey.isEmpty;
  String _lastText = '';

  Mode _mode = Mode.correct;
  String _lang = 'Urdu';
  // Each mode keeps its own status, error and request counter, so switching
  // Correct <-> Translate never discards the other mode's result.
  final _phases = {Mode.correct: Phase.idle, Mode.translate: Phase.idle};
  final _errors = <Mode, String?>{};
  final _reqs = {Mode.correct: 0, Mode.translate: 0};
  Phase get _phase => _phases[_mode]!;
  String? get _error => _errors[_mode];
  int get _req => _reqs[_mode]!;
  // Phone: the finished result takes the text box's place; a floating button
  // switches between the two. Per mode, like the results themselves.
  final _showResult = {Mode.correct: false, Mode.translate: false};
  bool get _hasResult => _phase == Phase.done;
  bool get _onResult => _hasResult && _showResult[_mode]!;

  String _corrected = '';
  List<Seg> _segs = const [];
  int _fixes = 0;
  String _translation = '';
  String _translatedLang = '';
  // Each new translation types itself out once; seen again (after a swipe
  // or a mode switch) it is shown whole.
  int _trSeq = 0;
  int _typedSeq = 0;
  EnglishResult? _english; // set when the target language is English

  bool _toneOpen = false;
  String _tone = 'Professional';
  final _toneCache = <String, String>{};
  final _toneLoading = <String>{};
  final _toneErrors = <String, String>{};

  final _history = <HistoryEntry>[];
  final _removing = <String>{};
  bool _histOpen = false;
  int _seq = 0;

  final _copied = <String, bool>{};
  final _copyTimers = <String, Timer>{};

  // Bumped when the app comes back to the foreground. Mobile Safari can drop
  // the GPU canvas while the tab is hidden; the text box keeps its old cached
  // drawing, so its text vanishes until something forces a redraw.
  int _redrawEpoch = 0;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _swipe = AnimationController.unbounded(vsync: this);
    _input.addListener(_onTextChanged);
    _lifecycle = AppLifecycleListener(
      onShow: _redrawText,
      onResume: _redrawText,
    );
  }

  /// Rebuild the text box from scratch (same controller, so the text and the
  /// cursor position are kept) after the tab/app becomes visible again.
  void _redrawText() {
    if (mounted) setState(() => _redrawEpoch++);
  }

  @override
  void dispose() {
    for (final t in _copyTimers.values) {
      t.cancel();
    }
    _lifecycle.dispose();
    _swipe.dispose();
    _input.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- actions

  void _onTextChanged() {
    if (_input.text == _lastText) return;
    _lastText = _input.text;
    // Results no longer match the text: reset both modes and drop any
    // in-flight answers for the old text.
    setState(_resetResults);
  }

  void _resetResults() {
    for (final m in Mode.values) {
      _phases[m] = Phase.idle;
      _showResult[m] = false;
      _errors[m] = null;
      _reqs[m] = _reqs[m]! + 1;
    }
  }

  void _setMode(Mode m) {
    if (_mode == m) return;
    setState(() {
      _mode = m; // results of both modes are kept
      if (m == Mode.translate) _toneOpen = false;
    });
  }

  void _pickLang(String name) {
    if (name == _lang) return;
    setState(() => _lang = name);
    if (_mode == Mode.translate && _phase == Phase.done) _run();
  }

  Future<void> _run() async {
    final mode = _mode;
    final text = _input.text.trim();
    if (text.isEmpty || _phases[mode] == Phase.checking) return;
    if (_noKey) {
      setState(() => _errors[mode] = _noKeyMessage);
      return;
    }
    final id = _reqs[mode]! + 1;
    final lang = _lang;
    setState(() {
      _reqs[mode] = id;
      _phases[mode] = Phase.checking;
      _errors[mode] = null;
    });
    // Still the answer we are waiting for (text unchanged, not re-run)?
    bool current() => mounted && _reqs[mode] == id;
    try {
      if (mode == Mode.correct) {
        final out = await _claude.correct(text);
        if (!current()) return;
        final segs = diffSegments(text, out);
        setState(() {
          _corrected = out;
          _segs = segs;
          _fixes = segs.where((s) => s.changed).length;
          _phases[mode] = Phase.done;
          _showResult[mode] = true;
          if (!_swipedOnce) _peek++;
        });
        _addHistory('Corrected', text, out);
      } else if (lang == 'English') {
        // English target: a word gets a definition, an English sentence gets
        // a plain-English explanation, anything else is translated.
        final r = await _claude.toEnglish(text);
        if (!current()) return;
        setState(() {
          _english = r;
          _translation = r.toPlainText();
          _trSeq++;
          _translatedLang = lang;
          _phases[mode] = Phase.done;
          _showResult[mode] = true;
          if (!_swipedOnce) _peek++;
        });
        if (r.isDefinition) {
          final first = r.meanings.isEmpty
              ? r.text
              : r.meanings.first.definition;
          _addHistory('Definition', text, '${r.word}: $first');
        } else {
          _addHistory(
            r.kind == 'explanation' ? 'Meaning' : 'English',
            text,
            r.text,
          );
        }
      } else {
        final out = await _claude.translate(text, lang);
        if (!current()) return;
        setState(() {
          _english = null;
          _translation = out;
          _trSeq++;
          _translatedLang = lang;
          _phases[mode] = Phase.done;
          _showResult[mode] = true;
          if (!_swipedOnce) _peek++;
        });
        _addHistory(lang, text, out);
      }
    } on ClaudeException catch (e) {
      if (!current()) return;
      setState(() {
        _phases[mode] = Phase.idle;
        _errors[mode] = e.message;
      });
    }
  }

  void _clear() {
    _input.clear();
    setState(_resetResults);
  }

  void _applyFix() => _input.text = _corrected;

  String _toneKey(String tone, String text) => '$tone\u0000$text';

  void _openTone() {
    setState(() => _toneOpen = true);
    _fetchTone();
  }

  void _closeTone() => setState(() => _toneOpen = false);

  void _pickTone(String name) {
    setState(() => _tone = name);
    _fetchTone();
  }

  Future<void> _fetchTone() async {
    final text = _input.text.trim();
    if (text.isEmpty || _noKey) return;
    final tone = _tone;
    final key = _toneKey(tone, text);
    if (_toneCache.containsKey(key) || _toneLoading.contains(key)) return;
    setState(() {
      _toneLoading.add(key);
      _toneErrors.remove(key);
    });
    try {
      final guide = tones.firstWhere((t) => t.name == tone).guide;
      final out = await _claude.rewrite(text, tone, guide);
      if (mounted) setState(() => _toneCache[key] = out);
    } on ClaudeException catch (e) {
      if (mounted) setState(() => _toneErrors[key] = e.message);
    } finally {
      if (mounted) setState(() => _toneLoading.remove(key));
    }
  }

  String? get _toneResult => _toneCache[_toneKey(_tone, _input.text.trim())];

  void _useTone() {
    final result = _toneResult;
    if (result == null) {
      _closeTone();
      return;
    }
    _addHistory(_tone, _input.text.trim(), result);
    _input.text = result;
    setState(() => _toneOpen = false);
  }

  void _copy(String flag, String value) {
    Clipboard.setData(ClipboardData(text: value));
    setState(() => _copied[flag] = true);
    _copyTimers[flag]?.cancel();
    _copyTimers[flag] = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _copied[flag] = false);
    });
  }

  void _addHistory(String kind, String before, String after) {
    if (_history.isNotEmpty &&
        _history.first.kind == kind &&
        _history.first.after == after) {
      return;
    }
    setState(
      () => _history.insert(
        0,
        HistoryEntry('h${++_seq}', kind, before, after, DateTime.now()),
      ),
    );
  }

  void _removeHistory(List<String> ids) {
    setState(() => _removing.addAll(ids));
    Timer(const Duration(milliseconds: 360), () {
      if (!mounted) return;
      setState(() {
        _history.removeWhere((h) => ids.contains(h.id));
        _removing.removeAll(ids);
      });
    });
  }

  void _restore(HistoryEntry h) {
    _input.text = h.after;
    setState(() => _histOpen = false);
  }

  String _when(DateTime at) {
    final mins = DateTime.now().difference(at).inMinutes;
    if (mins < 1) return 'Just now';
    if (mins < 60) return '$mins min ago';
    return '${at.hour}:${at.minute.toString().padLeft(2, '0')}';
  }

  // ----------------------------------------------------------------- layout

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_histOpen) {
            setState(() => _histOpen = false);
          } else if (_toneOpen) {
            _closeTone();
          }
        },
      },
      child: Scaffold(
        backgroundColor: TC.bg,
        body: LayoutBuilder(
          builder: (context, c) =>
              c.maxWidth < 900 ? _mobileLayout(c) : _webLayout(c),
        ),
      ),
    );
  }

  Widget _mobileLayout(BoxConstraints c) {
    return Stack(
      children: [
        const Positioned(
          top: -70,
          right: -60,
          child: DriftCircle(size: 220, seconds: 18, dashed: true),
        ),
        const Positioned(
          top: -20,
          right: -10,
          child: DriftCircle(size: 120, seconds: 12, reverse: true),
        ),
        SafeArea(
          child: ExcludeFocus(
            excluding: _histOpen || _toneOpen,
            child: Column(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(child: _mobileScroll()),
                      Positioned(
                        left: 20,
                        right: 20,
                        bottom: 8,
                        child: _swipeBar(),
                      ),
                    ],
                  ),
                ),
                // Pinned: always on screen, and right above the keyboard
                // when it is open.
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 520),
                      child: Rise(
                        delay: const Duration(milliseconds: 240),
                        child: _actionRow(web: false),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        ..._toneSheet(c),
        _mobileHistory(),
      ],
    );
  }

  /// Phone: the text box and, once there is one, the result beside it. The
  /// user swipes between the two cards.
  Widget _mobileSlot() {
    final result = !_hasResult
        ? null
        : AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            switchInCurve: easeOutSoft,
            layoutBuilder: (current, previous) => Stack(
              fit: StackFit.passthrough,
              alignment: Alignment.topCenter,
              children: [...previous, ?current],
            ),
            child: KeyedSubtree(
              key: ValueKey('slot-result-$_mode'),
              child: _mode == Mode.translate
                  ? _translationCard(web: false)
                  : _correctedCard(web: false),
            ),
          );
    return _SwipePager(
      controller: _swipe,
      page: _onResult ? 1 : 0,
      peek: _peek,
      onSwipe: (page) => setState(() {
        _showResult[_mode] = page == 1;
        _swipedOnce = true;
      }),
      first: _inputCard(web: false),
      second: result,
    );
  }

  String get _resultName {
    if (_mode == Mode.correct) return 'Correction';
    final e = _english;
    if (e == null || _translatedLang != 'English') return 'Translation';
    if (e.isDefinition) return 'Definition';
    return e.kind == 'explanation' ? 'Meaning' : 'Translation';
  }

  /// Floating indicator for the swipeable cards: a waving swipe hint, the two
  /// page names (tappable too, for mouse and screen-reader users) and dots
  /// that stretch and recolor live as the finger drags.
  Widget _swipeBar() {
    final show = _hasResult && !_histOpen && !_toneOpen;
    final color = _mode == Mode.translate ? TC.purple : TC.accent;
    void goTo(int page) => setState(() => _showResult[_mode] = page == 1);

    Widget bar() => AnimatedBuilder(
      animation: _swipe,
      builder: (context, _) {
        final p = _swipe.value.clamp(0.0, 1.0);
        Widget label(String text, String semantics, double on, int page) =>
            Pressable(
              label: semantics,
              radius: 18,
              lift: false,
              onTap: () => goTo(page),
              child: Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                alignment: Alignment.center,
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: inter(
                    size: 13,
                    weight: FontWeight.w600,
                    color: Color.lerp(TC.muted, color, on)!,
                  ),
                ),
              ),
            );
        Widget dot(double on) => Container(
          width: 6 + 14 * on,
          height: 6,
          margin: const EdgeInsets.symmetric(horizontal: 2.5),
          decoration: BoxDecoration(
            color: Color.lerp(TC.borderStrong, color, on),
            borderRadius: BorderRadius.circular(3),
          ),
        );
        return Container(
          height: 44,
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          decoration: BoxDecoration(
            color: TC.surface,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: Color.lerp(TC.border, color.withValues(alpha: 0.5), p)!,
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x80000000),
                blurRadius: 18,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _SwipeHint(active: !_swipedOnce),
              Flexible(
                child: label('Your text', 'Back to your text', 1 - p, 0),
              ),
              dot(1 - p),
              dot(p),
              Flexible(child: label(_resultName, 'Show $_resultName', p, 1)),
            ],
          ),
        );
      },
    );

    return Center(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 260),
        switchInCurve: easeOutSoft,
        transitionBuilder: (child, a) => FadeTransition(
          opacity: a,
          child: ScaleTransition(scale: a, child: child),
        ),
        child: show
            ? KeyedSubtree(key: const ValueKey('swipe-bar'), child: bar())
            : const SizedBox.shrink(key: ValueKey('swipe-none')),
      ),
    );
  }

  Widget _mobileScroll() {
    return
    // Content fades out softly as it reaches the button bar.
    ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: const [Colors.white, Colors.white, Colors.transparent],
        stops: [0, 1 - (20 / rect.height).clamp(0.0, 1.0), 1],
      ).createShader(rect),
      child: SingleChildScrollView(
        // Extra room at the bottom so the floating switch
        // never covers the end of the card.
        padding: EdgeInsets.fromLTRB(20, 24, 20, _hasResult ? 76 : 28),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Rise(child: _mobileHeader()),
                const SizedBox(height: 18),
                Rise(
                  delay: const Duration(milliseconds: 80),
                  child: _headline(web: false),
                ),
                const SizedBox(height: 18),
                Rise(
                  delay: const Duration(milliseconds: 120),
                  child: _modeBlock(),
                ),
                const SizedBox(height: 18),
                Rise(
                  delay: const Duration(milliseconds: 160),
                  child: _mobileSlot(),
                ),
                const SizedBox(height: 18),
                ..._results(web: false),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Below this height the page can't fit, so it scrolls instead.
  static const _fitMinHeight = 600.0;

  Widget _webLayout(BoxConstraints c) {
    // Fit the window: the text box takes whatever height is left, so the
    // action button is always on screen without scrolling.
    final fit = c.maxHeight >= _fitMinHeight;
    return Stack(
      children: [
        const Positioned(
          top: -110,
          right: -80,
          child: DriftCircle(size: 340, seconds: 20, dashed: true),
        ),
        const Positioned(
          top: -30,
          right: 10,
          child: DriftCircle(size: 180, seconds: 14, reverse: true),
        ),
        ExcludeFocus(
          excluding: _histOpen,
          child: fit
              ? _webPage(c, fit: true)
              : SingleChildScrollView(child: _webPage(c, fit: false)),
        ),
        ..._webHistory(c),
      ],
    );
  }

  /// Wide page. [fit]: fills the window height exactly (text box stretches,
  /// results scroll in their own column); otherwise natural height.
  Widget _webPage(BoxConstraints c, {required bool fit}) {
    final compact = c.maxHeight < 760; // short window: tighter spacing
    final left = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _modeBlock(),
        const SizedBox(height: 16),
        if (fit)
          Expanded(child: _inputCard(web: true, fill: true))
        else
          _inputCard(web: true),
        const SizedBox(height: 16),
        _actionRow(web: true),
      ],
    );
    final right = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: _results(web: true, gap: 16),
    );
    final columns = Row(
      crossAxisAlignment: fit
          ? CrossAxisAlignment.stretch
          : CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Rise(delay: const Duration(milliseconds: 160), child: left),
        ),
        const SizedBox(width: 24),
        Expanded(
          child: Rise(
            delay: const Duration(milliseconds: 240),
            child: fit
                ? SingleChildScrollView(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: right,
                  )
                : right,
          ),
        ),
      ],
    );
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1120),
        child: Padding(
          padding: EdgeInsets.fromLTRB(24, 20, 24, fit ? 24 : 56),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Rise(child: _webHeader()),
              SizedBox(height: compact ? 20 : 44),
              Rise(
                delay: const Duration(milliseconds: 80),
                child: _headline(web: true, compact: compact),
              ),
              SizedBox(height: compact ? 20 : 32),
              if (fit) Expanded(child: columns) else columns,
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- pieces

  Widget _brand(double logo, double size) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      ThinkletLogo(size: logo),
      const SizedBox(width: 10),
      Text(
        'Thinklet',
        style: grotesk(size: size, weight: FontWeight.w700, spacing: -0.3),
      ),
    ],
  );

  Widget _countBadge() => Pop(
    key: ValueKey(_history.length),
    child: Container(
      constraints: const BoxConstraints(minWidth: 20),
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 5),
      decoration: BoxDecoration(
        color: TC.accent,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Center(
        widthFactor: 1,
        child: Text(
          '${_history.length}',
          style: inter(size: 11, weight: FontWeight.w600, color: TC.bg),
        ),
      ),
    ),
  );

  Widget _mobileHeader() => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      _brand(38, 20),
      if (_historyEnabled)
        Stack(
          clipBehavior: Clip.none,
          children: [
            RoundIconButton(
              icon: Icons.history_rounded,
              label: 'Open history',
              onTap: () => setState(() => _histOpen = true),
            ),
            if (_history.isNotEmpty)
              Positioned(top: -4, right: -4, child: _countBadge()),
          ],
        ),
    ],
  );

  Widget _webHeader() => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      _brand(40, 22),
      if (_historyEnabled)
        Pressable(
          onTap: () => setState(() => _histOpen = true),
          radius: 22,
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: TC.surface,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: TC.borderStrong),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.history_rounded, size: 18, color: TC.text),
                const SizedBox(width: 8),
                Text('History', style: inter(weight: FontWeight.w500)),
                if (_history.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  _countBadge(),
                ],
              ],
            ),
          ),
        ),
    ],
  );

  Widget _headline({required bool web, bool compact = false}) => Semantics(
    header: true,
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(text: web ? 'Write it your way. ' : 'Write it your way.\n'),
          const TextSpan(
            text: "We'll make it right.",
            style: TextStyle(color: TC.accent),
          ),
        ],
      ),
      style: grotesk(
        size: web ? (compact ? 34 : 44) : 28,
        height: web ? 1.1 : 1.15,
        spacing: web ? -1 : -0.6,
      ),
    ),
  );

  Widget _modeBlock() {
    final translate = _mode == Mode.translate;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          label: 'Mode',
          container: true,
          child: Container(
            height: 52,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: TC.surface,
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: TC.border),
            ),
            child: Stack(
              children: [
                AnimatedAlign(
                  alignment: translate
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  duration: const Duration(milliseconds: 450),
                  curve: easeOutBack,
                  child: FractionallySizedBox(
                    widthFactor: 0.5,
                    heightFactor: 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: TC.accent,
                        borderRadius: BorderRadius.circular(22),
                      ),
                    ),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: _segButton(
                        'Correct',
                        Icons.check_rounded,
                        !translate,
                        () => _setMode(Mode.correct),
                      ),
                    ),
                    Expanded(
                      child: _segButton(
                        'Translate',
                        Icons.language_rounded,
                        translate,
                        () => _setMode(Mode.translate),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 300),
          curve: easeOutSoft,
          alignment: Alignment.topCenter,
          child: translate
              ? Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Rise(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Translate to',
                          style: inter(size: 13, color: TC.muted),
                        ),
                        const SizedBox(height: 8),
                        _LangStrip(selected: _lang, onPick: _pickLang),
                      ],
                    ),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  Widget _segButton(
    String label,
    IconData icon,
    bool selected,
    VoidCallback onTap,
  ) {
    final color = selected ? TC.bg : TC.textSoft;
    return Semantics(
      selected: selected,
      child: Pressable(
        onTap: onTap,
        label: label,
        radius: 22,
        lift: false,
        pressScale: 0.93,
        child: SizedBox(
          height: 44,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 8),
              Text(
                label,
                style: inter(weight: FontWeight.w600, color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// [fill]: the box takes all the height it is given (wide layout fitted
  /// to the window) instead of a fixed text area height.
  Widget _inputCard({required bool web, bool fill = false}) {
    final checking = _phase == Phase.checking;
    final pad = web ? 18.0 : 14.0;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: TC.surface,
        borderRadius: BorderRadius.circular(web ? 22 : 20),
        border: Border.all(color: checking ? TC.accent : TC.border),
      ),
      child: Stack(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(pad, pad, pad, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('YOUR LINE', style: capsLabel()),
                SizedBox(height: web ? 10 : 8),
                _flexOrFixed(
                  fill: fill,
                  height: web ? 220 : 132,
                  child: CallbackShortcuts(
                    bindings: {
                      const SingleActivator(
                        LogicalKeyboardKey.enter,
                        control: true,
                      ): _run,
                    },
                    // The placeholder is drawn here rather than passed as
                    // hintText: Flutter web copies hintText into its hidden
                    // HTML input, and iPhone Safari paints that copy as a
                    // stray "ghost" placeholder + caret near the field.
                    child: Stack(
                      children: [
                        if (_input.text.isEmpty)
                          IgnorePointer(
                            child: ExcludeSemantics(
                              child: Text(
                                'Type or paste your sentence here…',
                                style: inter(
                                  size: web ? 17 : 16,
                                  height: web ? 1.6 : 1.5,
                                  color: TC.placeholder,
                                ),
                              ),
                            ),
                          ),
                        Semantics(
                          label: 'Your line',
                          child: TextField(
                            key: ValueKey('input$_redrawEpoch'),
                            controller: _input,
                            // When revealing the caret, also bring the box's
                            // footer (count + Clear) and a gap into view so it
                            // doesn't butt against the pinned button bar.
                            scrollPadding: EdgeInsets.fromLTRB(
                              20,
                              20,
                              20,
                              // box height (132) + footer (54) + gap (22),
                              // so it holds wherever the caret is in the box
                              web ? 20 : 208,
                            ),
                            expands: true,
                            maxLines: null,
                            minLines: null,
                            textAlignVertical: TextAlignVertical.top,
                            cursorColor: TC.accent,
                            style: inter(
                              size: web ? 17 : 16,
                              height: web ? 1.6 : 1.5,
                            ),
                            decoration: const InputDecoration.collapsed(
                              hintText: null,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${_input.text.length} characters',
                      style: inter(size: web ? 13 : 12, color: TC.muted),
                    ),
                    Pressable(
                      onTap: _clear,
                      radius: 8,
                      child: Container(
                        height: 44,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        alignment: Alignment.center,
                        child: Text(
                          'Clear',
                          style: inter(
                            size: web ? 14 : 13,
                            weight: FontWeight.w500,
                            color: TC.muted,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (checking) ScanLine(top: web ? 44 : 36, travel: web ? 230 : 150),
        ],
      ),
    );
  }

  static Widget _flexOrFixed({
    required bool fill,
    required double height,
    required Widget child,
  }) => fill ? Expanded(child: child) : SizedBox(height: height, child: child);

  Widget _actionRow({required bool web}) {
    final checking = _phase == Phase.checking;
    final translate = _mode == Mode.translate;
    final h = web ? 46.0 : 44.0; // 44 px is the smallest comfortable tap size
    final fs = web ? 15.0 : 14.0;
    final primary = Pressable(
      onTap: _run,
      radius: 16,
      child: Container(
        height: h,
        decoration: BoxDecoration(
          color: TC.accent,
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [
            BoxShadow(
              color: Color(0xB3C6F24E),
              offset: Offset(0, 8),
              blurRadius: 24,
              spreadRadius: -10,
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (checking)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: TC.bg,
                ),
              )
            else
              Icon(
                translate ? Icons.language_rounded : Icons.check_rounded,
                size: 18,
                color: TC.bg,
              ),
            const SizedBox(width: 8),
            Text(
              checking
                  ? (translate ? 'Translating…' : 'Checking…')
                  : (translate ? 'Translate' : 'Correct'),
              style: inter(size: fs, weight: FontWeight.w600, color: TC.bg),
            ),
          ],
        ),
      ),
    );
    if (translate) return primary;
    // Equal widths: Tone on the left, Correct on the right.
    return Row(
      children: [
        Expanded(
          child: Semantics(
            selected: _toneOpen,
            child: Pressable(
              onTap: _openTone,
              radius: 16,
              child: Container(
                height: h,
                decoration: BoxDecoration(
                  color: TC.purpleTint,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: TC.purple),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.auto_awesome_outlined,
                      size: 18,
                      color: TC.purpleSoft,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Tone',
                      style: inter(
                        size: fs,
                        weight: FontWeight.w600,
                        color: TC.purpleSoft,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        SizedBox(width: web ? 12 : 10),
        Expanded(child: primary),
      ],
    );
  }

  // ---------------------------------------------------------------- results

  List<Widget> _results({required bool web, double gap = 0}) {
    final translate = _mode == Mode.translate;
    final out = <Widget>[];
    void add(Widget w) {
      if (out.isNotEmpty && gap > 0) out.add(SizedBox(height: gap));
      out.add(w);
    }

    if (_error != null) add(_errorCard());
    // Phone: no idle hint or "Reading…" line; the button and the scan line
    // on the text box already show what is happening.
    if (web && _phase == Phase.idle && _error == null && !_toneOpen) {
      add(_hint(web: web));
    }
    if (web && _phase == Phase.checking) add(_status(web: web));
    // On phones the finished card lives in the text box's slot instead.
    if (web && _phase == Phase.done && translate) {
      add(_translationCard(web: web));
    }
    if (web && _phase == Phase.done && !translate) {
      add(_correctedCard(web: web));
    }
    if (web && _toneOpen) {
      add(
        Rise(
          child: PanelCard(
            padding: 20,
            radius: 22,
            borderColor: TC.borderStrong,
            child: _tonePanel(web: true),
          ),
        ),
      );
    }
    return out;
  }

  Widget _errorCard() => Rise(
    key: ValueKey('err$_error'),
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: TC.dangerTint,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: TC.danger),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            size: 20,
            color: TC.dangerSoft,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _error!,
              style: inter(size: 14, height: 1.5, color: TC.dangerSoft),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _hint({required bool web}) {
    final text = _mode == Mode.translate
        ? 'Pick a language and press Translate. Tip: choose English and type '
              'one word to get its meaning.'
        : 'Press Correct to fix the grammar, or Tone to rewrite it in the style you need.';
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const BobDots(),
        const SizedBox(height: 14),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: web ? 300 : 260),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: inter(size: web ? 15 : 14, height: 1.5, color: TC.muted),
          ),
        ),
      ],
    );
    if (!web) {
      return Rise(
        key: ValueKey('hint$_mode'),
        delay: const Duration(milliseconds: 320),
        child: Container(
          constraints: const BoxConstraints(minHeight: 140),
          padding: const EdgeInsets.symmetric(vertical: 16),
          alignment: Alignment.center,
          child: content,
        ),
      );
    }
    return CustomPaint(
      painter: _DashedBorderPainter(),
      child: Container(
        constraints: const BoxConstraints(minHeight: 240),
        padding: const EdgeInsets.all(24),
        alignment: Alignment.center,
        child: content,
      ),
    );
  }

  Widget _status({required bool web}) {
    final row = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const PulseDot(),
        const SizedBox(width: 12),
        Text(
          _mode == Mode.translate
              ? 'Translating your sentence…'
              : 'Reading your sentence…',
          style: inter(size: web ? 15 : 14, color: TC.textSoft),
        ),
      ],
    );
    return Rise(
      child: Semantics(
        liveRegion: true,
        child: web
            ? Container(
                height: 120,
                decoration: BoxDecoration(
                  color: TC.surface,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: TC.border),
                ),
                child: row,
              )
            : SizedBox(height: 140, child: row),
      ),
    );
  }

  Widget _correctedCard({required bool web}) {
    final style = inter(size: web ? 17 : 16, height: web ? 1.7 : 1.65);
    final fx = style.copyWith(color: TC.accent);
    final spans = <InlineSpan>[];
    var k = 0;

    Widget chip(String t, int i) => Pop(
      delay: Duration(milliseconds: 150 + i * 90),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: TC.accentTint,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(t, style: fx),
      ),
    );

    for (final s in _segs) {
      if (!s.changed) {
        spans.add(TextSpan(text: s.text));
        continue;
      }
      final i = k++;
      if (s.text.length <= 24) {
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: chip(s.text, i),
          ),
        );
      } else {
        // Long changes: highlight word by word so lines can still wrap.
        for (final part in RegExp(r'\s+|\S+').allMatches(s.text)) {
          final w = part.group(0)!;
          spans.add(
            w.trim().isEmpty
                ? TextSpan(text: w)
                : WidgetSpan(
                    alignment: PlaceholderAlignment.baseline,
                    baseline: TextBaseline.alphabetic,
                    child: chip(w, i),
                  ),
          );
        }
      }
    }

    return Rise(
      key: ValueKey('corr$_req'),
      child: PanelCard(
        padding: web ? 20 : 16,
        radius: web ? 22 : 20,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('CORRECTED', style: capsLabel()),
                const SizedBox(width: 8),
                Pill(
                  _fixes == 0
                      ? 'Looks good'
                      : (_fixes == 1 ? '1 fix' : '$_fixes fixes'),
                ),
              ],
            ),
            SizedBox(height: web ? 14 : 12),
            SelectionArea(
              child: Text.rich(
                TextSpan(children: spans),
                style: style,
                semanticsLabel: _corrected,
              ),
            ),
            SizedBox(height: web ? 14 : 12),
            Row(
              children: [
                Expanded(
                  child: CopyButton(
                    label: 'Copy',
                    copied: _copied['fix'] == true,
                    onTap: () => _copy('fix', _corrected),
                    color: TC.accent,
                    tint: TC.accentFaint,
                    idleText: TC.accent,
                  ),
                ),
                SizedBox(width: web ? 10 : 8),
                Expanded(
                  child: GhostButton(label: 'Apply to text', onTap: _applyFix),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _translationCard({required bool web}) {
    final english = _translatedLang == 'English' ? _english : null;
    if (english != null && english.isDefinition) {
      return _definitionCard(english, web: web);
    }
    final rtl = _isRtl(_translatedLang);
    final label = english?.kind == 'explanation' ? 'MEANING' : 'TRANSLATION';
    final typeOut = _typedSeq != _trSeq;
    _typedSeq = _trSeq;
    return Rise(
      key: ValueKey('tr$_req'),
      child: PanelCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(label, style: capsLabel()),
                const SizedBox(width: 8),
                Pill(
                  english?.kind == 'explanation'
                      ? 'Simple English'
                      : _translatedLang,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Typewriter(
              text: english?.text ?? _translation,
              style: inter(size: rtl ? 18 : 16, height: 1.7),
              caretColor: TC.accent,
              textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
              animate: typeOut,
            ),
            const SizedBox(height: 12),
            CopyButton(
              label: english?.kind == 'explanation'
                  ? 'Copy'
                  : 'Copy translation',
              copied: _copied['trans'] == true,
              onTap: () => _copy('trans', _translation),
              color: TC.accent,
              tint: TC.accentFaint,
              idleText: TC.accent,
            ),
          ],
        ),
      ),
    );
  }

  /// Look up another word (e.g. a tapped synonym) in English mode.
  void _lookUp(String word) {
    _input.text = word;
    _run();
  }

  Widget _definitionCard(EnglishResult r, {required bool web}) {
    return Rise(
      key: ValueKey('def$_req'),
      child: PanelCard(
        padding: web ? 20 : 16,
        radius: web ? 22 : 20,
        child: SelectionArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('DEFINITION', style: capsLabel()),
                  const SizedBox(width: 8),
                  const Pill('Dictionary'),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.end,
                spacing: 10,
                runSpacing: 4,
                children: [
                  Text(
                    r.word,
                    style: grotesk(size: web ? 30 : 26, spacing: -0.5),
                  ),
                  if (r.phonetic.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        r.phonetic,
                        style: inter(size: 15, color: TC.muted),
                      ),
                    ),
                ],
              ),
              if (r.text.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  r.text,
                  style: inter(size: 15, height: 1.5, color: TC.textSoft),
                ),
              ],
              for (final (i, m) in r.meanings.indexed) ...[
                const SizedBox(height: 14),
                Pop(
                  delay: Duration(milliseconds: 150 + i * 90),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: TC.purpleTint,
                      borderRadius: BorderRadius.circular(11),
                      border: Border.all(color: TC.purpleBorder),
                    ),
                    child: Text(
                      m.partOfSpeech,
                      style: inter(
                        size: 12,
                        weight: FontWeight.w600,
                        color: TC.purpleSoft,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${i + 1}. ${m.definition}',
                  style: inter(size: web ? 17 : 16, height: 1.55),
                ),
                if (m.example.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.only(left: 12),
                    decoration: const BoxDecoration(
                      border: Border(
                        left: BorderSide(color: TC.borderStrong, width: 2),
                      ),
                    ),
                    child: Text(
                      '“${m.example}”',
                      style: inter(
                        size: 15,
                        height: 1.5,
                        color: TC.muted,
                      ).copyWith(fontStyle: FontStyle.italic),
                    ),
                  ),
                ],
              ],
              if (r.synonyms.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('SYNONYMS', style: capsLabel()),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final s in r.synonyms)
                      Pressable(
                        onTap: () => _lookUp(s),
                        label: 'Define $s',
                        radius: 18,
                        lift: false,
                        child: Container(
                          height: 36,
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: TC.borderStrong),
                          ),
                          child: Center(
                            widthFactor: 1,
                            child: Text(
                              s,
                              style: inter(size: 14, weight: FontWeight.w500),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              SizedBox(height: web ? 16 : 14),
              CopyButton(
                label: 'Copy definition',
                copied: _copied['trans'] == true,
                onTap: () => _copy('trans', r.toPlainText()),
                color: TC.accent,
                tint: TC.accentFaint,
                idleText: TC.accent,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ tone

  Widget _tonePanel({required bool web}) {
    final text = _input.text.trim();
    final key = _toneKey(_tone, text);
    final result = _toneCache[key];
    final loading = _toneLoading.contains(key);
    final error = _toneErrors[key];
    final fs = web ? 17.0 : 16.0;

    Widget preview;
    if (text.isEmpty) {
      preview = Text(
        'Write a line first, then pick a tone.',
        style: inter(size: fs, height: 1.6, color: TC.muted),
      );
    } else if (_noKey) {
      preview = Text(
        _noKeyMessage,
        style: inter(size: 14, height: 1.5, color: TC.dangerSoft),
      );
    } else if (result != null) {
      preview = Typewriter(
        text: result,
        style: inter(size: fs, height: 1.6),
        caretColor: TC.purple,
      );
    } else if (loading) {
      preview = Row(
        children: [
          const PulseDot(color: TC.purple),
          const SizedBox(width: 12),
          Text(
            'Rewriting in a ${_tone.toLowerCase()} tone…',
            style: inter(size: 14, color: TC.textSoft),
          ),
        ],
      );
    } else if (error != null) {
      preview = Text(
        '$error Tap a tone to try again.',
        style: inter(size: 14, height: 1.5, color: TC.dangerSoft),
      );
    } else {
      preview = Text(
        'Pick a tone to rewrite your line.',
        style: inter(size: fs, height: 1.6, color: TC.muted),
      );
    }

    final h = web ? 50.0 : 54.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(
                'How should it sound?',
                style: grotesk(size: 20, spacing: -0.3),
              ),
            ),
            RoundIconButton(
              icon: Icons.close_rounded,
              label: 'Close tone suggestions',
              onTap: _closeTone,
              filled: false,
            ),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final t in tones)
              ChoiceChipButton(
                label: t.name,
                selected: t.name == _tone,
                onTap: () => _pickTone(t.name),
                activeColor: TC.purple,
                idleText: TC.purpleSoft,
                idleBorder: TC.purpleBorder,
              ),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          constraints: BoxConstraints(minHeight: web ? 132 : 168),
          padding: EdgeInsets.all(web ? 16 : 14),
          decoration: BoxDecoration(
            color: TC.bg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: TC.border),
          ),
          child: Semantics(
            liveRegion: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_tone.toUpperCase(), style: capsLabel(TC.purple)),
                const SizedBox(height: 8),
                preview,
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              flex: 2,
              child: CopyButton(
                label: 'Copy',
                copied: _copied['tone'] == true,
                onTap: () => _copy('tone', result ?? ''),
                color: TC.purple,
                tint: TC.purpleTint,
                idleText: TC.purpleSoft,
                height: h,
                enabled: result != null,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 3,
              child: Opacity(
                opacity: result != null ? 1 : .45,
                child: Pressable(
                  onTap: result != null ? _useTone : null,
                  radius: 16,
                  child: Container(
                    height: h,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: TC.purple,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      'Use this version',
                      style: inter(
                        size: 15,
                        weight: FontWeight.w600,
                        color: TC.bg,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  List<Widget> _toneSheet(BoxConstraints c) => [
    Positioned.fill(
      child: IgnorePointer(
        ignoring: !_toneOpen,
        child: AnimatedOpacity(
          opacity: _toneOpen ? 1 : 0,
          duration: const Duration(milliseconds: 400),
          child: Semantics(
            button: true,
            label: 'Close tone suggestions',
            child: GestureDetector(
              onTap: _closeTone,
              child: const ColoredBox(color: TC.backdrop),
            ),
          ),
        ),
      ),
    ),
    Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        ignoring: !_toneOpen,
        child: ExcludeFocus(
          excluding: !_toneOpen,
          child: AnimatedSlide(
            offset: _toneOpen ? Offset.zero : const Offset(0, 1.05),
            duration: const Duration(milliseconds: 500),
            curve: easeOutSoft,
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 560,
                  maxHeight: c.maxHeight * 0.88,
                ),
                child: Container(
                  decoration: const BoxDecoration(
                    color: TC.surface,
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(28),
                    ),
                    border: Border(top: BorderSide(color: TC.borderStrong)),
                  ),
                  child: SafeArea(
                    top: false,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 10, 20, 22),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Center(
                            child: Container(
                              width: 40,
                              height: 4,
                              decoration: BoxDecoration(
                                color: TC.borderStrong,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          _tonePanel(web: false),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  ];

  // --------------------------------------------------------------- history

  Widget _historyPanel({required bool web}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 10,
            runSpacing: 10,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RoundIconButton(
                    icon: web
                        ? Icons.close_rounded
                        : Icons.arrow_back_ios_new_rounded,
                    label: web ? 'Close history' : 'Back',
                    onTap: () => setState(() => _histOpen = false),
                  ),
                  const SizedBox(width: 10),
                  Semantics(
                    header: true,
                    child: Text(
                      'History',
                      style: grotesk(size: 22, spacing: -0.4),
                    ),
                  ),
                ],
              ),
              if (_history.isNotEmpty)
                Pressable(
                  onTap: () =>
                      _removeHistory(_history.map((h) => h.id).toList()),
                  radius: 22,
                  child: Container(
                    height: 44,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: TC.dangerTint,
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(color: TC.danger),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.delete_outline_rounded,
                          size: 16,
                          color: TC.dangerSoft,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Delete all',
                          style: inter(
                            size: 13,
                            weight: FontWeight.w600,
                            color: TC.dangerSoft,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 18),
          Expanded(
            child: _history.isEmpty
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: TC.borderStrong),
                        ),
                        child: const Icon(
                          Icons.schedule_rounded,
                          size: 28,
                          color: TC.muted,
                        ),
                      ),
                      const SizedBox(height: 14),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 250),
                        child: Text(
                          'Nothing here yet. Lines you correct, translate or rewrite are saved here.',
                          textAlign: TextAlign.center,
                          style: inter(size: 14, height: 1.5, color: TC.muted),
                        ),
                      ),
                    ],
                  )
                : ListView(
                    children: [for (final h in _history) _historyTile(h)],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _historyTile(HistoryEntry h) {
    final gone = _removing.contains(h.id);
    final isTone = tones.any((t) => t.name == h.kind);
    final kindColor = isTone ? TC.purple : TC.accent;
    return AnimatedOpacity(
      key: ValueKey(h.id),
      opacity: gone ? 0 : 1,
      duration: const Duration(milliseconds: 250),
      child: AnimatedSlide(
        offset: gone ? const Offset(0.15, 0) : Offset.zero,
        duration: const Duration(milliseconds: 300),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 350),
          alignment: Alignment.topCenter,
          child: gone
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Rise(
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
                      decoration: BoxDecoration(
                        color: TC.surface,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: TC.border),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Pressable(
                              onTap: () => _restore(h),
                              label: 'Use this line again',
                              radius: 12,
                              lift: false,
                              pressScale: 0.98,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          h.kind.toUpperCase(),
                                          style: inter(
                                            size: 11,
                                            weight: FontWeight.w600,
                                            spacing: 0.6,
                                            color: kindColor,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          _when(h.at),
                                          style: inter(
                                            size: 12,
                                            color: TC.muted,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    SizedBox(
                                      width: double.infinity,
                                      child: Text(
                                        h.after,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        textDirection: _isRtl(h.kind)
                                            ? TextDirection.rtl
                                            : null,
                                        style: inter(size: 15, height: 1.45),
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      'From: ${h.before}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: inter(
                                        size: 13,
                                        height: 1.4,
                                        color: TC.muted,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          RoundIconButton(
                            icon: Icons.delete_outline_rounded,
                            label: 'Delete this entry',
                            onTap: () => _removeHistory([h.id]),
                            filled: false,
                            border: false,
                            color: TC.dangerSoft,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  Widget _mobileHistory() => Positioned.fill(
    child: IgnorePointer(
      ignoring: !_histOpen,
      child: ExcludeFocus(
        excluding: !_histOpen,
        child: ExcludeSemantics(
          excluding: !_histOpen,
          child: AnimatedSlide(
            offset: _histOpen ? Offset.zero : const Offset(1, 0),
            duration: const Duration(milliseconds: 500),
            curve: easeOutSoft,
            child: ColoredBox(
              color: TC.bg,
              child: SafeArea(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: _historyPanel(web: false),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  List<Widget> _webHistory(BoxConstraints c) => [
    Positioned.fill(
      child: IgnorePointer(
        ignoring: !_histOpen,
        child: AnimatedOpacity(
          opacity: _histOpen ? 1 : 0,
          duration: const Duration(milliseconds: 400),
          child: Semantics(
            button: true,
            label: 'Close history',
            child: GestureDetector(
              onTap: () => setState(() => _histOpen = false),
              child: const ColoredBox(color: TC.backdrop),
            ),
          ),
        ),
      ),
    ),
    Positioned(
      top: 0,
      bottom: 0,
      right: 0,
      width: math.min(420, c.maxWidth),
      child: IgnorePointer(
        ignoring: !_histOpen,
        child: ExcludeFocus(
          excluding: !_histOpen,
          child: ExcludeSemantics(
            excluding: !_histOpen,
            child: AnimatedSlide(
              offset: _histOpen ? Offset.zero : const Offset(1.05, 0),
              duration: const Duration(milliseconds: 500),
              curve: easeOutSoft,
              child: Container(
                decoration: const BoxDecoration(
                  color: TC.bg,
                  border: Border(left: BorderSide(color: TC.borderStrong)),
                ),
                child: _historyPanel(web: true),
              ),
            ),
          ),
        ),
      ),
    ),
  ];
}

/// One horizontally scrollable row of language chips. Works with touch,
/// mouse drag, trackpad and the mouse wheel; edges fade to hint at more.
class _LangStrip extends StatefulWidget {
  const _LangStrip({required this.selected, required this.onPick});
  final String selected;
  final ValueChanged<String> onPick;

  @override
  State<_LangStrip> createState() => _LangStripState();
}

class _LangStripState extends State<_LangStrip> {
  final _scroll = ScrollController();
  bool _fadeLeft = false, _fadeRight = false;

  /// Fade an edge only while more chips are hidden past it.
  bool _updateFades(ScrollMetrics m) {
    final left = m.pixels > m.minScrollExtent + 1;
    final right = m.pixels < m.maxScrollExtent - 1;
    if (left != _fadeLeft || right != _fadeRight) {
      setState(() {
        _fadeLeft = left;
        _fadeRight = right;
      });
    }
    return false;
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const fade = 32.0;
    return SizedBox(
      height: 44,
      child: ShaderMask(
        shaderCallback: (rect) {
          final f = (fade / rect.width).clamp(0.0, 0.5);
          return LinearGradient(
            colors: [
              _fadeLeft ? Colors.transparent : Colors.white,
              Colors.white,
              Colors.white,
              _fadeRight ? Colors.transparent : Colors.white,
            ],
            stops: [0, f, 1 - f, 1],
          ).createShader(rect);
        },
        blendMode: BlendMode.dstIn,
        child: NotificationListener<ScrollMetricsNotification>(
          onNotification: (n) => _updateFades(n.metrics),
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) => _updateFades(n.metrics),
            child: _strip(context),
          ),
        ),
      ),
    );
  }

  Widget _strip(BuildContext context) {
    return Listener(
      // Turn vertical mouse-wheel scrolling into sideways scrolling.
      onPointerSignal: (e) {
        if (e is PointerScrollEvent && _scroll.hasClients) {
          final pos = _scroll.position;
          final delta = e.scrollDelta.dy != 0
              ? e.scrollDelta.dy
              : e.scrollDelta.dx;
          _scroll.jumpTo(
            (pos.pixels + delta).clamp(
              pos.minScrollExtent,
              pos.maxScrollExtent,
            ),
          );
        }
      },
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          scrollbars: false,
          dragDevices: PointerDeviceKind.values.toSet(),
        ),
        child: ListView.separated(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          itemCount: languages.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (_, i) {
            final l = languages[i];
            return ChoiceChipButton(
              label: l.name,
              selected: l.name == widget.selected,
              onTap: () => widget.onPick(l.name),
              activeColor: TC.accent,
              idleText: TC.text,
              idleBorder: TC.borderStrong,
            );
          },
        ),
      ),
    );
  }
}

/// Two cards side by side that follow the finger: drag sideways and both
/// slide (the one leaving shrinks and dims a little), let go and a spring
/// carries on with the finger's speed to the nearer card, or the one the
/// flick points to. Dragging past either end rubber-bands.
///
/// While settled only the shown card is built, so the hidden text box can't
/// hold focus or be read out.
class _SwipePager extends StatefulWidget {
  const _SwipePager({
    required this.controller,
    required this.first,
    required this.second,
    required this.page,
    required this.onSwipe,
    required this.peek,
  });

  /// 0 = first card, 1 = second; values in between while moving.
  final AnimationController controller;
  final Widget first;

  /// Null when there is nothing to swipe to.
  final Widget? second;
  final int page;
  final ValueChanged<int> onSwipe;

  /// Bumped to nudge toward the first card and back, hinting at the swipe.
  final int peek;

  @override
  State<_SwipePager> createState() => _SwipePagerState();
}

class _SwipePagerState extends State<_SwipePager> {
  static const _gap = 28.0; // keeps the hidden card out of the side margin
  static final _spring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 300,
    ratio: 0.86,
  );

  AnimationController get _c => widget.controller;
  late int _target = widget.page;
  // The last result card, kept while it slides away after being removed.
  late Widget? _second = widget.second;
  bool _dragging = false;
  double _width = 1;
  Timer? _peekTimer;

  @override
  void initState() {
    super.initState();
    // Built straight onto the result (e.g. after a resize): match the
    // indicator, after this frame so it isn't rebuilt mid-build.
    if (_c.value != _target) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_dragging) _c.value = _target.toDouble();
      });
    }
  }

  @override
  void didUpdateWidget(_SwipePager old) {
    super.didUpdateWidget(old);
    if (widget.second != null) _second = widget.second;
    final page = widget.second == null ? 0 : widget.page;
    if (page != _target && !_dragging) _springTo(page);
    if (widget.peek != old.peek) {
      _peekTimer?.cancel();
      _peekTimer = Timer(const Duration(milliseconds: 700), _doPeek);
    }
  }

  @override
  void dispose() {
    _peekTimer?.cancel();
    super.dispose();
  }

  void _springTo(int page, [double velocity = 0]) {
    _target = page;
    _c
        .animateWith(
          SpringSimulation(
            _spring,
            _c.value,
            page.toDouble(),
            velocity,
            tolerance: const Tolerance(distance: 0.001, velocity: 0.01),
          ),
        )
        .whenCompleteOrCancel(_settled);
  }

  /// Rebuild once still, to drop the hidden card (or a removed result).
  void _settled() {
    if (!mounted || _dragging || _c.isAnimating) return;
    setState(() {
      if (widget.second == null && _target == 0) _second = null;
    });
  }

  void _doPeek() {
    if (!mounted || _dragging || _target != 1 || _second == null) return;
    _c
        .animateTo(
          0.9,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        )
        .then((_) {
          if (mounted && !_dragging && _target == 1) _springTo(1);
        });
  }

  void _dragStart(DragStartDetails d) {
    _peekTimer?.cancel();
    _c.stop();
    setState(() => _dragging = true);
  }

  void _dragUpdate(DragUpdateDetails d) {
    final delta = -(d.primaryDelta ?? 0) / _width;
    final v = _c.value;
    // Past either end the card only moves a third as far (rubber band).
    final outside = (v <= 0 && delta < 0) || (v >= 1 && delta > 0);
    _c.value = (v + (outside ? delta / 3 : delta)).clamp(-0.12, 1.12);
  }

  void _dragEnd(double velocityPx) {
    final v = -velocityPx / _width; // pages per second, + toward the result
    final page = v.abs() > 0.7 ? (v > 0 ? 1 : 0) : (_c.value > 0.5 ? 1 : 0);
    setState(() => _dragging = false);
    _springTo(page, v);
    if (page != widget.page) widget.onSwipe(page);
  }

  @override
  Widget build(BuildContext context) {
    final second = _second;
    final gestures = <Type, GestureRecognizerFactory>{
      if (second != null)
        _SwipeRecognizer:
            GestureRecognizerFactoryWithHandlers<_SwipeRecognizer>(
              () => _SwipeRecognizer(debugOwner: this),
              (r) => r
                ..onStart = _dragStart
                ..onUpdate = _dragUpdate
                ..onEnd = ((d) => _dragEnd(d.primaryVelocity ?? 0))
                ..onCancel = (() => _dragEnd(0)),
            ),
    };
    return LayoutBuilder(
      builder: (context, c) {
        _width = math.max(c.maxWidth, 1);
        final span = c.maxWidth + _gap;
        return RawGestureDetector(
          gestures: gestures,
          behavior: HitTestBehavior.translucent,
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              final moving = _dragging || _c.isAnimating;
              final t = moving ? _c.value : _target.toDouble();
              final p = t.clamp(0.0, 1.0);
              Widget card(String key, Widget child, double dx, double away) =>
                  KeyedSubtree(
                    key: ValueKey(key),
                    child: Transform.translate(
                      offset: Offset(dx, 0),
                      child: Transform.scale(
                        scale: 1 - 0.06 * away,
                        child: Opacity(opacity: 1 - 0.5 * away, child: child),
                      ),
                    ),
                  );
              return Stack(
                fit: StackFit.passthrough,
                alignment: Alignment.topCenter,
                clipBehavior: Clip.none,
                children: [
                  if (second == null || moving || _target == 0)
                    card('page-text', widget.first, -t * span, p),
                  if (second != null && (moving || _target == 1))
                    card('page-result', second, (1 - t) * span, 1 - p),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

/// Horizontal drag that claims the gesture after a short, clearly sideways
/// move, before the text box / selectable text under it can take it for
/// text selection. Mostly-vertical moves are left to the page scroll. Touch
/// and pen only: a mouse drag still selects text (the indicator is clickable).
class _SwipeRecognizer extends HorizontalDragGestureRecognizer {
  _SwipeRecognizer({super.debugOwner})
    : super(
        supportedDevices: {
          PointerDeviceKind.touch,
          PointerDeviceKind.stylus,
          PointerDeviceKind.invertedStylus,
          PointerDeviceKind.trackpad,
          PointerDeviceKind.unknown,
        },
      );

  Offset _down = Offset.zero;
  double _dy = 0;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _down = event.position;
    _dy = 0;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) _dy = (event.position - _down).dy;
    super.handleEvent(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) {
    final dx = globalDistanceMoved.abs();
    return dx > 6 && dx > _dy.abs() * 1.3;
  }
}

/// Swipe icon that sways side to side until the user has swiped once.
class _SwipeHint extends StatefulWidget {
  const _SwipeHint({required this.active});
  final bool active;

  @override
  State<_SwipeHint> createState() => _SwipeHintState();
}

class _SwipeHintState extends State<_SwipeHint>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _c.repeat();
  }

  @override
  void didUpdateWidget(_SwipeHint old) {
    super.didUpdateWidget(old);
    if (widget.active && !_c.isAnimating) _c.repeat();
    if (!widget.active && _c.isAnimating) {
      _c.animateTo(1, duration: const Duration(milliseconds: 300));
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) {
          // Two quick sways, then a rest, each cycle.
          final t = (_c.value * 1.6).clamp(0.0, 1.0);
          final sway = math.sin(t * 2 * math.pi * 2) * (1 - t);
          return Transform.translate(
            offset: Offset(sway * 5, 0),
            child: Transform.rotate(angle: sway * 0.18, child: child),
          );
        },
        child: Icon(
          Icons.swipe_rounded,
          size: 18,
          color: widget.active ? TC.textSoft : TC.muted,
        ),
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(22),
    );
    final path = Path()..addRRect(rrect.deflate(0.5));
    final paint = Paint()
      ..color = TC.borderStrong
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, d + 4), paint);
        d += 8;
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
