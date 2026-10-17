import 'package:flutter/material.dart';

import '../app/theme.dart';

/// A round profile photo with the person's initials as the fallback.
///
/// Photo links from the API expire after about 10 minutes, so a failed load
/// (or no photo) shows the initials instead of a broken image.
class UserAvatar extends StatelessWidget {
  const UserAvatar({
    super.key,
    required this.initials,
    this.url,
    this.radius = 16,
    this.background = AppColors.primarySoft,
    this.foreground = AppColors.primary,
  });

  final String initials;
  final String? url;
  final double radius;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final fallback = Center(
      child: Text(
        initials,
        style: TextStyle(
          fontSize: radius * 0.75,
          fontWeight: FontWeight.w600,
          color: foreground,
        ),
      ),
    );
    final link = url;
    return CircleAvatar(
      radius: radius,
      backgroundColor: background,
      child: link == null || link.isEmpty
          ? fallback
          : ClipOval(
              child: Image.network(
                link,
                width: radius * 2,
                height: radius * 2,
                fit: BoxFit.cover,
                semanticLabel: 'Profile photo',
                errorBuilder: (_, _, _) => fallback,
              ),
            ),
    );
  }
}
