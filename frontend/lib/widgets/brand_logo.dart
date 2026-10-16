import 'package:flutter/material.dart';

import '../app/theme.dart';

/// The Pruflo mark (infinity loop) with the word mark beside it.
class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key, this.size = 22, this.light = false});

  final double size;

  /// White text for dark backgrounds such as the sidebar and splash.
  final bool light;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.all_inclusive,
            size: size * 1.3,
            color: light ? const Color(0xFF4F86FF) : AppColors.primary),
        SizedBox(width: size * 0.35),
        Flexible(
          child: Text(
            'PruFlo',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: size,
              fontWeight: FontWeight.w700,
              color: light ? Colors.white : AppColors.navy,
            ),
          ),
        ),
      ],
    );
  }
}
