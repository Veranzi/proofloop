import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/auth_service.dart';
import '../../core/formatters.dart';
import '../../core/api.dart';
import '../../core/models.dart';
import '../../widgets/async_view.dart';
import '../../widgets/case_tile.dart';
import '../../widgets/page_header.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardData {
  const _DashboardData(this.cases, this.truncated, this.activity);
  final List<CaseItem> cases; // newest first
  final bool truncated;
  final List<ActivityItem> activity;
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _api = PrufloApi();
  late Future<_DashboardData> _future = _load();

  Future<_DashboardData> _load() async {
    final (cases, truncated) = await _api.allCases();
    final activity = await _api.activity(limit: 6);
    return _DashboardData(cases, truncated, activity);
  }

  void _reload() => setState(() { _future = _load(); });

  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    final user = AuthService.instance.user;
    final wide = MediaQuery.sizeOf(context).width >= 1100;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: user == null
                ? _greeting()
                : '${_greeting()}, ${user.firstName}',
            subtitle: "Here's what's happening with your cases.",
          ),
          AsyncView<_DashboardData>(
            future: _future,
            onRetry: _reload,
            builder: (context, data) => _content(context, data, wide),
          ),
        ],
      ),
    );
  }

  Widget _content(BuildContext context, _DashboardData data, bool wide) {
    final cases = data.cases;
    int count(CaseStatus s) => cases.where((c) => c.status == s).length;
    final stats = [
      _Stat('Total Cases', cases.length, AppColors.textSecondary),
      _Stat('In Review', count(CaseStatus.inReview), AppColors.primary),
      _Stat('Awaiting Evidence', count(CaseStatus.awaitingEvidence),
          AppColors.warning),
      _Stat('Completed', count(CaseStatus.completed), AppColors.success),
    ];
    final canEdit = AuthService.instance.user?.role.canEditCases ?? false;

    final recentCases = SectionCard(
      title: 'Recent Cases',
      trailing: TextButton(
        onPressed: () => context.go('/cases'),
        child: const Text('View all'),
      ),
      child: cases.isEmpty
          ? EmptyPanel(
              title: 'No cases yet',
              message: canEdit
                  ? 'Create a case to start collecting evidence.'
                  : 'Cases you are added to will appear here.',
            )
          : Column(children: [for (final c in cases.take(4)) CaseTile(c)]),
    );

    final sidePanel = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (canEdit) ...[
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
        ],
        SectionCard(
          title: 'Recent Activity',
          child: data.activity.isEmpty
              ? const EmptyPanel(
                  title: 'No activity yet',
                  message: 'Your uploads, decisions and reports show here.',
                )
              : Column(
                  children: [for (final a in data.activity) _ActivityRow(a)],
                ),
        ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StatGrid(stats),
        if (data.truncated)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('Counts include your 1,000 most recent cases.',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          ),
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
                if (item.caseReference != null)
                  Text('Case #${item.caseReference}',
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
