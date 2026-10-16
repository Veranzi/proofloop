import 'package:flutter/material.dart';

import '../app/theme.dart';

/// The Pruflo logo artwork, shared by the app's brand widgets.
class PrufloMark {
  static const asset = 'assets/brand/pruflo_mark.png';
}

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
        Image.asset(PrufloMark.asset, height: size * 1.1),
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
