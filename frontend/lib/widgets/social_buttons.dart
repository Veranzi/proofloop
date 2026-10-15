import 'package:flutter/material.dart';

/// "Continue with Google / Microsoft" buttons. Firebase Auth supports both
/// providers; wire them up in [AuthService.signInWithProvider].
class SocialButtons extends StatelessWidget {
  const SocialButtons({super.key, required this.onPressed, this.compact = false});

  final void Function(String provider) onPressed;

  /// Side by side with short labels (mobile mockup) instead of stacked.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final google = OutlinedButton.icon(
      onPressed: () => onPressed('google'),
      icon: const _GoogleMark(),
      label: Text(compact ? 'Google' : 'Continue with Google'),
    );
    final microsoft = OutlinedButton.icon(
      onPressed: () => onPressed('microsoft'),
      icon: const _MicrosoftMark(),
      label: Text(compact ? 'Microsoft' : 'Continue with Microsoft'),
    );

    if (compact) {
      return Row(
        children: [
          Expanded(child: google),
          const SizedBox(width: 12),
          Expanded(child: microsoft),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [google, const SizedBox(height: 12), microsoft],
    );
  }
}

class _GoogleMark extends StatelessWidget {
  const _GoogleMark();

  @override
  Widget build(BuildContext context) {
    return const Text('G',
        style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: Color(0xFF4285F4)));
  }
}

class _MicrosoftMark extends StatelessWidget {
  const _MicrosoftMark();

  @override
  Widget build(BuildContext context) {
    Widget square(Color c) => Container(width: 7, height: 7, color: c);
    return SizedBox(
      width: 16,
      height: 16,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              square(const Color(0xFFF25022)),
              square(const Color(0xFF7FBA00)),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              square(const Color(0xFF00A4EF)),
              square(const Color(0xFFFFB900)),
            ],
          ),
        ],
      ),
    );
  }
}
