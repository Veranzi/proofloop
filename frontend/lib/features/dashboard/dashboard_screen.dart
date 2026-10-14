import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/auth_service.dart';
import '../../core/formatters.dart';
import '../../core/mock_repository.dart';
import '../../core/models.dart';
import '../../widgets/case_tile.dart';
import '../../widgets/page_header.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    final repo = MockRepository.instance;
    final cases = repo.cases();
    final user = AuthService.instance.user;
    final wide = MediaQuery.sizeOf(context).width >= 1100;

    int count(CaseStatus s) => cases.where((c) => c.status == s).length;
    final stats = [
      _Stat('Total Cases', cases.length, AppColors.textSecondary),
      _Stat('In Review', count(CaseStatus.inReview), AppColors.primary),
      _Stat('Awaiting Evidence', count(CaseStatus.awaitingEvidence),
          AppColors.warning),
      _Stat('Completed', count(CaseStatus.completed), AppColors.success),
    ];

    final recentCases = SectionCard(
      title: 'Recent Cases',
      trailing: TextButton(
        onPressed: () => context.go('/cases'),
        child: const Text('View all'),
      ),
      child: Column(
        children: [for (final c in cases.take(4)) CaseTile(c)],
      ),
    );

    final sidePanel = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionCard(
          title: 'Quick Actions',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton(
                onPressed: () => context.go('/evidence'),
                child: const Text('Upload Evidence'),
              ),
              const SizedBox(height: 10),
              OutlinedButton(
                onPressed: () => context.go('/cases?new=1'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  side: const BorderSide(color: AppColors.primary),
                ),
                child: const Text('Create New Case'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Recent Activity',
          child: Column(
            children: [
              for (final a in repo.activity()) _ActivityRow(a),
            ],
          ),
        ),
      ],
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: '${_greeting()}, ${user?.firstName ?? 'there'}',
            subtitle: "Here's what's happening with your cases.",
          ),
          _StatGrid(stats),
          const SizedBox(height: 20),
          if (wide)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: recentCases),
                const SizedBox(width: 20),
                Expanded(flex: 2, child: sidePanel),
              ],
            )
          else ...[
            recentCases,
            const SizedBox(height: 16),
            sidePanel,
          ],
        ],
      ),
    );
  }
}

class _Stat {
  const _Stat(this.label, this.value, this.color);
  final String label;
  final int value;
  final Color color;
}

/// Four stat cards in a row, or a 2x2 grid on narrow screens.
class _StatGrid extends StatelessWidget {
  const _StatGrid(this.stats);
  final List<_Stat> stats;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final perRow = constraints.maxWidth >= 700 ? 4 : 2;
      const gap = 16.0;
      final width = (constraints.maxWidth - gap * (perRow - 1)) / perRow;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final s in stats)
            SizedBox(
              width: width,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${s.value}',
                          style: const TextStyle(
                              fontSize: 26, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text(s.label,
                          style: TextStyle(fontSize: 12, color: s.color)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      );
    });
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow(this.item);
  final ActivityItem item;

  @override
  Widget build(BuildContext context) {
    final icon = switch (item.kind) {
      ActivityKind.evidenceUploaded => Icons.upload_file_outlined,
      ActivityKind.reviewCompleted => Icons.fact_check_outlined,
      ActivityKind.reportGenerated => Icons.description_outlined,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: AppColors.primarySoft,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 16, color: AppColors.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.title,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w500)),
                Text('Case #${item.caseId}',
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textSecondary)),
              ],
            ),
          ),
          Text(timeAgo(item.at),
              style:
                  const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}
