import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../app/theme.dart';
import '../core/formatters.dart';
import '../core/models.dart';
import 'status_chip.dart';

/// One row in a "Recent cases" list: icon, id, title, status and age.
class CaseTile extends StatelessWidget {
  const CaseTile(this.item, {super.key});

  final CaseItem item;

  @override
  Widget build(BuildContext context) {
    final (iconBg, iconFg) = switch (item.status) {
      CaseStatus.inReview => (AppColors.primarySoft, AppColors.primary),
      CaseStatus.awaitingEvidence => (AppColors.warningSoft, AppColors.warning),
      CaseStatus.completed => (AppColors.successSoft, AppColors.success),
    };

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => context.go('/cases/${item.id}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.work_outline, size: 18, color: iconFg),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Case #${item.id}',
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 13)),
                  const SizedBox(height: 2),
                  Text(item.title,
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textSecondary)),
                ],
              ),
            ),
            StatusChip(item.status),
            const SizedBox(width: 12),
            SizedBox(
              width: 52,
              child: Text(timeAgo(item.createdAt),
                  textAlign: TextAlign.end,
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textSecondary)),
            ),
          ],
        ),
      ),
    );
  }
}
