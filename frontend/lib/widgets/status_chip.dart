import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../core/models.dart';

/// Small rounded label used for case status, priority and user state.
class Pill extends StatelessWidget {
  const Pill(this.label,
      {super.key, required this.foreground, required this.background});

  final String label;
  final Color foreground;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
            fontSize: 11, fontWeight: FontWeight.w600, color: foreground),
      ),
    );
  }
}

class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key});
  final CaseStatus status;

  @override
  Widget build(BuildContext context) {
    return switch (status) {
      CaseStatus.inReview => const Pill('In Review',
          foreground: AppColors.primary, background: AppColors.primarySoft),
      CaseStatus.awaitingEvidence => const Pill('Awaiting Evidence',
          foreground: AppColors.warning, background: AppColors.warningSoft),
      CaseStatus.completed => const Pill('Completed',
          foreground: AppColors.success, background: AppColors.successSoft),
    };
  }
}

class PriorityChip extends StatelessWidget {
  const PriorityChip(this.priority, {super.key});
  final Priority priority;

  @override
  Widget build(BuildContext context) {
    return switch (priority) {
      Priority.high => const Pill('High',
          foreground: AppColors.danger, background: AppColors.dangerSoft),
      Priority.medium => const Pill('Medium',
          foreground: AppColors.warning, background: AppColors.warningSoft),
      Priority.low => const Pill('Low',
          foreground: AppColors.success, background: AppColors.successSoft),
    };
  }
}

String statusLabel(CaseStatus s) => switch (s) {
      CaseStatus.inReview => 'In Review',
      CaseStatus.awaitingEvidence => 'Awaiting Evidence',
      CaseStatus.completed => 'Completed',
    };

String roleLabel(UserRole r) => switch (r) {
      UserRole.investigator => 'Investigator',
      UserRole.reviewer => 'Reviewer',
      UserRole.admin => 'Admin',
      UserRole.viewer => 'Viewer',
    };
