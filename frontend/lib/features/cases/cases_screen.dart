import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/formatters.dart';
import '../../core/mock_repository.dart';
import '../../core/models.dart';
import '../../widgets/page_header.dart';
import '../../widgets/status_chip.dart';
import 'new_case_dialog.dart';

/// Case management: search, filter by status, open or create a case.
class CasesScreen extends StatefulWidget {
  const CasesScreen({super.key, this.openNewCase = false});

  /// Opens the "New Case" dialog on arrival (dashboard quick action).
  final bool openNewCase;

  @override
  State<CasesScreen> createState() => _CasesScreenState();
}

class _CasesScreenState extends State<CasesScreen> {
  String _query = '';
  CaseStatus? _status;

  @override
  void initState() {
    super.initState();
    if (widget.openNewCase) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _newCase());
    }
  }

  Future<void> _newCase() async {
    final created = await showNewCaseDialog(context);
    if (created == null || !mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Case #${created.id} created')),
    );
  }

  List<CaseItem> get _filtered {
    final q = _query.toLowerCase();
    return MockRepository.instance.cases().where((c) {
      final matchesQuery = q.isEmpty ||
          c.id.toLowerCase().contains(q) ||
          c.title.toLowerCase().contains(q);
      final matchesStatus = _status == null || c.status == _status;
      return matchesQuery && matchesStatus;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final cases = _filtered;

    final filters = Row(
      children: [
        Expanded(
          child: TextField(
            onChanged: (v) => setState(() => _query = v),
            decoration: const InputDecoration(
              hintText: 'Search cases...',
              prefixIcon: Icon(Icons.search, size: 18),
            ),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: wide ? 200 : 150,
          child: DropdownButtonFormField<CaseStatus?>(
            initialValue: _status,
            isExpanded: true,
            items: [
              const DropdownMenuItem(value: null, child: Text('All Statuses')),
              for (final s in CaseStatus.values)
                DropdownMenuItem(value: s, child: Text(statusLabel(s))),
            ],
            onChanged: (v) => setState(() => _status = v),
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
            title: 'Cases',
            subtitle: 'Manage and track all your cases',
            action: FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
              onPressed: _newCase,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New Case'),
            ),
          ),
          SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                filters,
                const SizedBox(height: 16),
                if (cases.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 40),
                    child: Center(
                      child: Text('No cases match your search.',
                          style: TextStyle(color: AppColors.textSecondary)),
                    ),
                  )
                else if (wide)
                  _CasesTable(cases)
                else
                  for (final c in cases) _CaseCard(c),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CasesTable extends StatelessWidget {
  const _CasesTable(this.cases);
  final List<CaseItem> cases;

  @override
  Widget build(BuildContext context) {
    const header = TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: AppColors.textSecondary);

    Widget cell(Widget child, int flex) => Expanded(flex: flex, child: child);

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          color: AppColors.background,
          child: Row(
            children: [
              cell(const Text('ID', style: header), 2),
              cell(const Text('Title', style: header), 4),
              cell(const Text('Status', style: header), 3),
              cell(const Text('Priority', style: header), 2),
              cell(const Text('Created', style: header), 2),
              cell(const Text('Actions', style: header), 2),
            ],
          ),
        ),
        for (final c in cases)
          InkWell(
            onTap: () => context.go('/cases/${c.id}'),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: AppColors.border)),
              ),
              child: Row(
                children: [
                  cell(Text(c.id, style: const TextStyle(fontSize: 13)), 2),
                  cell(
                      Text(c.title,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w500)),
                      4),
                  cell(Align(
                      alignment: Alignment.centerLeft,
                      child: StatusChip(c.status)), 3),
                  cell(Align(
                      alignment: Alignment.centerLeft,
                      child: PriorityChip(c.priority)), 2),
                  cell(
                      Text(timeAgo(c.createdAt),
                          style: const TextStyle(
                              fontSize: 13, color: AppColors.textSecondary)),
                      2),
                  cell(
                      Row(
                        children: [
                          IconButton(
                            tooltip: 'View case',
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.visibility_outlined,
                                size: 18),
                            onPressed: () => context.go('/cases/${c.id}'),
                          ),
                          _CaseMenu(c),
                        ],
                      ),
                      2),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _CaseMenu extends StatelessWidget {
  const _CaseMenu(this.item);
  final CaseItem item;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'More actions',
      icon: const Icon(Icons.more_vert, size: 18),
      onSelected: (v) => switch (v) {
        'evidence' => context.go('/evidence?case=${item.id}'),
        'review' => context.go('/review?case=${item.id}'),
        _ => context.go('/reports?case=${item.id}'),
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'evidence', child: Text('Upload evidence')),
        PopupMenuItem(value: 'review', child: Text('Open review')),
        PopupMenuItem(value: 'report', child: Text('Generate report')),
      ],
    );
  }
}

/// Mobile version of a table row.
class _CaseCard extends StatelessWidget {
  const _CaseCard(this.item);
  final CaseItem item;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => context.go('/cases/${item.id}'),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('Case #${item.id}',
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textSecondary)),
                    const Spacer(),
                    Text(timeAgo(item.createdAt),
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textSecondary)),
                  ],
                ),
                const SizedBox(height: 4),
                Text(item.title,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [StatusChip(item.status), PriorityChip(item.priority)],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
