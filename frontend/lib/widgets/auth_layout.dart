import 'package:flutter/material.dart';

import 'brand_logo.dart';

/// Centred, width-limited card used by every sign-in related screen.
class AuthLayout extends StatelessWidget {
  const AuthLayout({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
    this.showLogo = true,
  });

  final String title;
  final String subtitle;
  final Widget child;
  final bool showLogo;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 600;
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showLogo) ...[
          const Center(child: BrandLogo()),
          const SizedBox(height: 28),
        ],
        Text(title,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(subtitle,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
        const SizedBox(height: 28),
        child,
      ],
    );

    return Scaffold(
      backgroundColor: wide ? null : Colors.white,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: wide
                  ? Card(
                      child: Padding(
                        padding: const EdgeInsets.all(36),
                        child: content,
                      ),
                    )
                  : content,
            ),
          ),
        ),
      ),
    );
  }
}

/// "or continue with" divider.
class OrDivider extends StatelessWidget {
  const OrDivider({super.key, this.label = 'or continue with'});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Expanded(child: Divider()),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
        const Expanded(child: Divider()),
      ],
    );
  }
}
