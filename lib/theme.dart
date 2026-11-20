import 'package:flutter/material.dart';

/// Thinklet design tokens (dark theme, lime accent, purple for tone).
class TC {
  static const bg = Color(0xFF0E1116);
  static const surface = Color(0xFF171B22);
  static const border = Color(0xFF262C36);
  static const borderStrong = Color(0xFF353D4A);
  static const dashed = Color(0xFF2E3643);
  static const text = Color(0xFFF2F4F7);
  static const textSoft = Color(0xFFC9CFD9);
  static const muted = Color(0xFF9AA3B2);
  static const placeholder = Color(0xFF8B94A3);
  static const dot = Color(0xFF5B6472);
  static const accent = Color(0xFFC6F24E);
  static const accentTint = Color(0x1FC6F24E); // 12%
  static const accentFaint = Color(0x14C6F24E); // 8%
  static const purple = Color(0xFFB9A6FF);
  static const purpleSoft = Color(0xFFD5C9FF);
  static const purpleBorder = Color(0xFF4A4368);
  static const purpleTint = Color(0x1AB9A6FF); // 10%
  static const danger = Color(0xFFFF9A85);
  static const dangerSoft = Color(0xFFFFB3A3);
  static const dangerTint = Color(0x1AFF9A85);
  static const backdrop = Color(0x9E06080B); // 62%
}

TextStyle inter({
  double size = 14,
  FontWeight weight = FontWeight.w400,
  Color color = TC.text,
  double? height,
  double? spacing,
}) => TextStyle(
  fontFamily: 'Inter',
  fontSize: size,
  fontWeight: weight,
  color: color,
  height: height,
  letterSpacing: spacing,
);

TextStyle grotesk({
  double size = 20,
  FontWeight weight = FontWeight.w600,
  Color color = TC.text,
  double? height,
  double? spacing,
}) => TextStyle(
  fontFamily: 'SpaceGrotesk',
  fontSize: size,
  fontWeight: weight,
  color: color,
  height: height,
  letterSpacing: spacing,
);

/// Small uppercase section label ("YOUR LINE", "CORRECTED"...).
TextStyle capsLabel([Color color = TC.muted]) =>
    inter(size: 12, weight: FontWeight.w600, spacing: 0.6, color: color);

const easeOutBack = Cubic(.2, .9, .25, 1.1);
const easeOutSoft = Cubic(.2, .9, .25, 1);
const easeRise = Cubic(.2, .8, .2, 1);
