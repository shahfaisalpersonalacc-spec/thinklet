import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// Button base: hover lift, press shrink, keyboard focus ring.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.label,
    this.radius = 16,
    this.lift = true,
    this.pressScale = 0.95,
  });

  final Widget child;
  final VoidCallback? onTap;
  final String? label;
  final double radius;
  final bool lift;
  final double pressScale;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _hover = false, _down = false, _focus = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        onShowHoverHighlight: (v) => setState(() => _hover = v),
        onShowFocusHighlight: (v) => setState(() => _focus = v),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: enabled ? (_) => setState(() => _down = true) : null,
          onTapUp: enabled ? (_) => setState(() => _down = false) : null,
          onTapCancel: enabled ? () => setState(() => _down = false) : null,
          onTap: widget.onTap,
          child: AnimatedScale(
            scale: _down ? widget.pressScale : 1,
            duration: const Duration(milliseconds: 150),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              transform: Matrix4.translationValues(
                0,
                _hover && widget.lift && enabled ? -2 : 0,
                0,
              ),
              foregroundDecoration: _focus
                  ? BoxDecoration(
                      borderRadius: BorderRadius.circular(widget.radius + 2),
                      border: Border.all(color: TC.accent, width: 2),
                    )
                  : null,
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

/// Fade + slide up on first appearance.
class Rise extends StatefulWidget {
  const Rise({super.key, required this.child, this.delay = Duration.zero});
  final Widget child;
  final Duration delay;

  @override
  State<Rise> createState() => _RiseState();
}

class _RiseState extends State<Rise> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  );
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer(widget.delay, () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) {
        final v = easeRise.transform(_c.value);
        return Opacity(
          opacity: v,
          child: Transform.translate(
            offset: Offset(0, 18 * (1 - v)),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// Springy scale-in (0.6 -> 1.12 -> 1).
class Pop extends StatefulWidget {
  const Pop({super.key, required this.child, this.delay = Duration.zero});
  final Widget child;
  final Duration delay;

  @override
  State<Pop> createState() => _PopState();
}

class _PopState extends State<Pop> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  );
  Timer? _t;

  static final _scale = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0.6, end: 1.12), weight: 60),
    TweenSequenceItem(tween: Tween(begin: 1.12, end: 1.0), weight: 40),
  ]);

  @override
  void initState() {
    super.initState();
    _t = Timer(widget.delay, () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) => Opacity(
        opacity: (_c.value / 0.6).clamp(0.0, 1.0),
        child: Transform.scale(scale: _scale.transform(_c.value), child: child),
      ),
      child: widget.child,
    );
  }
}

/// Thinklet mark: a thought bubble with a check.
class ThinkletLogo extends StatelessWidget {
  const ThinkletLogo({super.key, this.size = 38});
  final double size;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _LogoPainter());
}

class _LogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 64);
    canvas.drawRRect(
      RRect.fromLTRBR(0, 0, 64, 64, const Radius.circular(14)),
      Paint()..color = TC.surface,
    );
    canvas.drawRRect(
      RRect.fromLTRBR(10, 10, 54, 44, const Radius.circular(11)),
      Paint()..color = TC.accent,
    );
    canvas.drawPath(
      Path()
        ..moveTo(22, 27)
        ..lineTo(29, 34)
        ..lineTo(42, 19),
      Paint()
        ..color = TC.bg
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawCircle(const Offset(17, 52), 4.5, Paint()..color = TC.accent);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Slowly drifting decorative ring.
class DriftCircle extends StatefulWidget {
  const DriftCircle({
    super.key,
    required this.size,
    required this.seconds,
    this.dashed = false,
    this.reverse = false,
  });
  final double size;
  final int seconds;
  final bool dashed;
  final bool reverse;

  @override
  State<DriftCircle> createState() => _DriftCircleState();
}

class _DriftCircleState extends State<DriftCircle>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: Duration(seconds: widget.seconds),
  )..repeat();

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
        builder: (_, _) {
          final t = widget.reverse ? 1 - _c.value : _c.value;
          final s = math.sin(math.pi * t);
          return Transform.translate(
            offset: Offset(-14 * s, 10 * s),
            child: Transform.rotate(
              angle: 2 * math.pi * t,
              child: CustomPaint(
                size: Size.square(widget.size),
                painter: _RingPainter(widget.dashed),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.dashed);
  final bool dashed;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = dashed ? TC.dashed : TC.border;
    final rect = Rect.fromCircle(center: Offset(r, r), radius: r);
    if (!dashed) {
      canvas.drawOval(rect, paint);
      return;
    }
    final count = (2 * math.pi * r / 6).floor();
    final step = 2 * math.pi / count;
    for (var i = 0; i < count; i += 2) {
      canvas.drawArc(rect, i * step, step, false, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) => old.dashed != dashed;
}

/// Three bobbing dots used in empty/hint states.
class BobDots extends StatefulWidget {
  const BobDots({super.key});
  @override
  State<BobDots> createState() => _BobDotsState();
}

class _BobDotsState extends State<BobDots> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const colors = [TC.accent, TC.purple, TC.dot];
    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              Transform.translate(
                offset: Offset(
                  0,
                  -6 *
                      (0.5 -
                          0.5 * math.cos(2 * math.pi * (_c.value - i * 0.143))),
                ),
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: colors[i],
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Pulsing status dot.
class PulseDot extends StatefulWidget {
  const PulseDot({super.key, this.color = TC.accent});
  final Color color;
  @override
  State<PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<PulseDot>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        final k = 0.5 - 0.5 * math.cos(2 * math.pi * _c.value);
        return Opacity(
          opacity: 0.9 - 0.55 * k,
          child: Transform.scale(
            scale: 1 + 0.35 * k,
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: widget.color,
                shape: BoxShape.circle,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Glowing line that sweeps down the input while Claude is working.
class ScanLine extends StatefulWidget {
  const ScanLine({super.key, required this.top, required this.travel});
  final double top;
  final double travel;
  @override
  State<ScanLine> createState() => _ScanLineState();
}

class _ScanLineState extends State<ScanLine>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        final t = Curves.easeInOut.transform(_c.value);
        final v = _c.value;
        final op = v < .12 ? v / .12 : (v > .88 ? (1 - v) / .12 : 1.0);
        return Positioned(
          left: 0,
          right: 0,
          top: widget.top + widget.travel * t,
          child: IgnorePointer(
            child: Opacity(
              opacity: op.clamp(0.0, 1.0),
              child: Container(
                height: 2,
                decoration: const BoxDecoration(
                  color: TC.accent,
                  boxShadow: [
                    BoxShadow(
                      color: Color(0x73C6F24E),
                      blurRadius: 18,
                      spreadRadius: 4,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Reveals [text] two characters at a time with a blinking caret.
class Typewriter extends StatefulWidget {
  const Typewriter({
    super.key,
    required this.text,
    required this.style,
    required this.caretColor,
    this.textDirection,
    this.animate = true,
  });
  final String text;
  final TextStyle style;
  final Color caretColor;
  final TextDirection? textDirection;

  /// False: show the whole text at once (it was already typed out before).
  final bool animate;

  @override
  State<Typewriter> createState() => _TypewriterState();
}

class _TypewriterState extends State<Typewriter> {
  Timer? _timer;
  int _shown = 0;
  bool _blinkOn = true;
  Timer? _blink;

  @override
  void initState() {
    super.initState();
    if (widget.animate) {
      _start();
    } else {
      _shown = widget.text.characters.length;
    }
  }

  @override
  void didUpdateWidget(covariant Typewriter old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) _start();
  }

  void _start() {
    _timer?.cancel();
    _blink?.cancel();
    _shown = 0;
    _blinkOn = true;
    final total = widget.text.characters.length;
    _timer = Timer.periodic(const Duration(milliseconds: 18), (t) {
      setState(() => _shown = math.min(total, _shown + 2));
      if (_shown >= total) {
        t.cancel();
        _blink?.cancel();
      }
    });
    _blink = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => setState(() => _blinkOn = !_blinkOn),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _blink?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.text.characters.length;
    final typing = _shown < total;
    return SelectionArea(
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: widget.text.characters.take(_shown).toString()),
            if (typing)
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Opacity(
                  opacity: _blinkOn ? 1 : 0,
                  child: Container(
                    width: 2,
                    height: (widget.style.fontSize ?? 16) + 2,
                    margin: const EdgeInsets.only(left: 2),
                    color: widget.caretColor,
                  ),
                ),
              ),
          ],
        ),
        style: widget.style,
        textDirection: widget.textDirection,
        semanticsLabel: widget.text,
      ),
    );
  }
}

/// Small filled pill ("3 fixes", "Urdu").
class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.color = TC.accent});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Pop(
      delay: const Duration(milliseconds: 200),
      child: Container(
        height: 22,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(11),
        ),
        child: Center(
          widthFactor: 1,
          child: Text(
            text,
            style: inter(size: 12, weight: FontWeight.w600, color: TC.bg),
          ),
        ),
      ),
    );
  }
}

/// Round chip button used for languages and tones.
class ChoiceChipButton extends StatelessWidget {
  const ChoiceChipButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.activeColor,
    required this.idleText,
    required this.idleBorder,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color activeColor;
  final Color idleText;
  final Color idleBorder;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      child: Pressable(
        onTap: onTap,
        label: label,
        radius: 22,
        lift: false,
        pressScale: 0.93,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: selected ? activeColor : Colors.transparent,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: selected ? activeColor : idleBorder),
          ),
          child: Center(
            widthFactor: 1,
            child: Text(
              label,
              style: inter(
                weight: FontWeight.w600,
                color: selected ? TC.bg : idleText,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Outline button that flips to filled "Copied" for 1.6 s.
class CopyButton extends StatelessWidget {
  const CopyButton({
    super.key,
    required this.label,
    required this.copied,
    required this.onTap,
    required this.color,
    required this.tint,
    required this.idleText,
    this.height = 46,
    this.enabled = true,
  });
  final String label;
  final bool copied;
  final VoidCallback onTap;
  final Color color;
  final Color tint;
  final Color idleText;
  final double height;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final fg = copied ? TC.bg : idleText;
    return Opacity(
      opacity: enabled ? 1 : .45,
      child: Pressable(
        onTap: enabled ? onTap : null,
        radius: 14,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: height,
          decoration: BoxDecoration(
            color: copied ? color : tint,
            borderRadius: BorderRadius.circular(height > 48 ? 16 : 14),
            border: Border.all(color: color),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              copied
                  ? Pop(child: Icon(Icons.check_rounded, size: 18, color: fg))
                  : Icon(Icons.copy_rounded, size: 17, color: fg),
              const SizedBox(width: 8),
              Text(
                copied ? 'Copied' : label,
                style: inter(
                  size: height > 48 ? 15 : 14,
                  weight: FontWeight.w600,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Plain outline button ("Apply to text").
class GhostButton extends StatelessWidget {
  const GhostButton({super.key, required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      radius: 14,
      child: Container(
        height: 46,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: TC.borderStrong),
        ),
        child: Text(label, style: inter(weight: FontWeight.w600)),
      ),
    );
  }
}

/// 44 px round icon button.
class RoundIconButton extends StatelessWidget {
  const RoundIconButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.filled = true,
    this.color = TC.text,
    this.border = true,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool filled;
  final Color color;
  final bool border;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      label: label,
      radius: 22,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: filled ? TC.surface : Colors.transparent,
          border: border ? Border.all(color: TC.borderStrong) : null,
        ),
        child: Icon(icon, size: 19, color: color),
      ),
    );
  }
}

/// Surface card used by result/tone panels.
class PanelCard extends StatelessWidget {
  const PanelCard({
    super.key,
    required this.child,
    this.padding = 16,
    this.radius = 20,
    this.borderColor = TC.border,
  });
  final Widget child;
  final double padding;
  final double radius;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(padding),
      decoration: BoxDecoration(
        color: TC.surface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderColor),
      ),
      child: child,
    );
  }
}
