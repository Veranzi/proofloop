import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/auth_service.dart';
import '../../widgets/auth_layout.dart';

/// Shown after sign-up while the user confirms their email address.
class VerifyEmailScreen extends StatefulWidget {
  const VerifyEmailScreen({super.key, required this.email});

  final String email;

  @override
  State<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends State<VerifyEmailScreen> {
  bool _sending = false;

  Future<void> _resend() async {
    setState(() => _sending = true);
    await AuthService.instance.resendVerification(widget.email);
    if (!mounted) return;
    setState(() => _sending = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Verification email sent again.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AuthLayout(
      showLogo: false,
      title: 'Check your email',
      subtitle: "We've sent a verification link to",
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Transform.translate(
            offset: const Offset(0, -20),
            child: Text(
              widget.email.isEmpty ? 'your email address' : widget.email,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          const Center(child: _EnvelopeIllustration()),
          const SizedBox(height: 24),
          const Text(
            'Click the link in your email to verify your account.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 16),
          Center(
            child: TextButton(
              onPressed: _sending ? null : _resend,
              child: Text(_sending ? 'Sending…' : 'Resend email'),
            ),
          ),
          Center(
            child: TextButton(
              onPressed: () => context.go('/login'),
              child: const Text('Back to login'),
            ),
          ),
        ],
      ),
    );
  }
}

class _EnvelopeIllustration extends StatelessWidget {
  const _EnvelopeIllustration();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 120,
      height: 120,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            decoration: const BoxDecoration(
              color: AppColors.primarySoft,
              shape: BoxShape.circle,
            ),
          ),
          const Icon(Icons.mail_outline, size: 56, color: AppColors.primary),
          Positioned(
            right: 22,
            bottom: 26,
            child: Container(
              decoration: const BoxDecoration(
                color: AppColors.success,
                shape: BoxShape.circle,
              ),
              padding: const EdgeInsets.all(3),
              child: const Icon(Icons.check, size: 14, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}
