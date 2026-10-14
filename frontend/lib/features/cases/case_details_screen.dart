import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/formatters.dart';
import '../../core/mock_repository.dart';
import '../../core/models.dart';
import '../../widgets/status_chip.dart';

/// One case: overview, its evidence and its timeline (GET /v1/cases/{id}).
class CaseDetailsScreen extends StatelessWidget {
  const CaseDetailsScreen({super.key, required this.caseId});

  final String caseId;

  @override
  Widget build(BuildContext context) {
    final item = MockRepository.instance.caseById(caseId);
    if (item == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Case #$caseId was not found.'),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => context.go('/cases'),
              child: const Text('Back to cases'),
            ),
          ],
        ),
      );
    }

    return DefaultTabController(
      length: 3,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(12, 12, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    IconButton(
                      tooltip: 'Back to cases',
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => context.go('/cases'),
                    ),
                    Text('Case #${item.id}',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 12, top: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        children: [
                          StatusChip(item.status),
                          PriorityChip(item.priority),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(item.title,
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                const TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: [
                    Tab(text: 'Overview'),
                    Tab(text: 'Evidence'),
                    Tab(text: 'Timeline'),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: TabBarView(
              children: [
                _OverviewTab(item),
                _EvidenceTab(item),
                _TimelineTab(item),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _OverviewTab extends StatelessWidget {
  const _OverviewTab(this.item);
  final CaseItem item;

  @override
  Widget build(BuildContext context) {
    Widget field(String label, Widget value) => Padding(
          padding: const EdgeInsets.only(bottom: 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textSecondary)),
              const SizedBox(height: 4),
              value,
            ],
          ),
        );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              field('Description', Text(item.description)),
              field('Category', Text(item.category)),
              field('Created', Text(formatDateTime(item.createdAt))),
              field(
                'Assigned to',
                Text(item.assignedTo,
                    style: const TextStyle(fontWeight: FontWeight.w500)),
              ),
              field(
                'Priority',
                Align(
                    alignment: Alignment.centerLeft,
                    child: PriorityChip(item.priority)),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () =>
                    DefaultTabController.of(context).animateTo(1),
                child: const Text('View Evidence'),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => context.go('/review?case=${item.id}'),
                child: const Text('Open Review Workspace'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EvidenceTab extends StatelessWidget {
  const _EvidenceTab(this.item);
  final CaseItem item;

  @override
  Widget build(BuildContext context) {
    final files = MockRepository.instance
        .recentEvidence()
        .where((e) => e.caseId == item.id)
        .toList();

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        if (files.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text('No evidence uploaded for this case yet.',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
        for (final f in files)
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined,
                  color: AppColors.danger),
              title: Text(f.name),
              subtitle: Text('${f.sizeLabel} · ${f.type}'),
              trailing: Text(timeAgo(f.uploadedAt),
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textSecondary)),
            ),
          ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: () => context.go('/evidence?case=${item.id}'),
            icon: const Icon(Icons.cloud_upload_outlined, size: 18),
            label: const Text('Upload evidence'),
          ),
        ),
      ],
    );
  }
}

class _TimelineTab extends StatelessWidget {
  const _TimelineTab(this.item);
  final CaseItem item;

  @override
  Widget build(BuildContext context) {
    // GET /v1/cases/{caseId}/timeline (endpoint 16) once the API exists.
    final events = [
      ('Case created by ${item.assignedTo}', item.createdAt),
      (
        'Status set to ${statusLabel(item.status)}',
        item.createdAt.add(const Duration(minutes: 20)),
      ),
    ];

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        for (final (label, at) in events.reversed)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.circle, size: 10, color: AppColors.primary),
            minLeadingWidth: 16,
            title: Text(label, style: const TextStyle(fontSize: 14)),
            subtitle: Text(formatDateTime(at),
                style: const TextStyle(fontSize: 12)),
          ),
      ],
    );
  }
}
