import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Brand colours taken from the ProofLoop UI mockups.
class AppColors {
  AppColors._();

  static const navy = Color(0xFF0A1A3F);
  static const navyLight = Color(0xFF1B3570);
  static const primary = Color(0xFF1652F0);
  static const primarySoft = Color(0xFFE8F0FE);

  static const background = Color(0xFFF5F7FB);
  static const surface = Colors.white;
  static const border = Color(0xFFE3E8F0);

  static const textPrimary = Color(0xFF0F172A);
  static const textSecondary = Color(0xFF64748B);

  static const success = Color(0xFF15803D);
  static const successSoft = Color(0xFFE7F7EE);
  static const warning = Color(0xFFB45309);
  static const warningSoft = Color(0xFFFFF4E5);
  static const danger = Color(0xFFDC2626);
  static const dangerSoft = Color(0xFFFDECEC);
}

class AppTheme {
  AppTheme._();

  static ThemeData light() {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.primary,
        primary: AppColors.primary,
        surface: AppColors.surface,
      ),
      scaffoldBackgroundColor: AppColors.background,
    );

    final textTheme = GoogleFonts.interTextTheme(base.textTheme).apply(
      bodyColor: AppColors.textPrimary,
      displayColor: AppColors.textPrimary,
    );

    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: AppColors.border),
    );

    return base.copyWith(
      textTheme: textTheme,
      dividerColor: AppColors.border,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        hintStyle: const TextStyle(color: AppColors.textSecondary),
        border: inputBorder,
        enabledBorder: inputBorder,
        focusedBorder: inputBorder.copyWith(
          borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          minimumSize: const Size.fromHeight(48),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.textPrimary,
          minimumSize: const Size.fromHeight(48),
          side: const BorderSide(color: AppColors.border),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      cardTheme: CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.border),
        ),
      ),
    );
  }
}
