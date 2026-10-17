import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/formatters.dart';
import '../../core/api.dart';
import '../../core/auth_service.dart';
import '../../core/models.dart';
import '../../widgets/async_view.dart';
import '../../widgets/page_header.dart';
import '../../widgets/status_chip.dart';
import 'new_case_dialog.dart';

/// Case management: search, filter by status, open or create a case.
/// Search and filters run on the server (GET /v1/cases?q=&status=).
class CasesScreen extends StatefulWidget {
  const CasesScreen({super.key, this.openNewCase = false, this.initialQuery});

  /// Opens the "New Case" dialog on arrival (dashboard quick action).
  final bool openNewCase;

  /// From the top bar's search box.
  final String? initialQuery;

  @override
  State<CasesScreen> createState() => _CasesScreenState();
}

class _CasesScreenState extends State<CasesScreen> {
  final _api = PrufloApi();
  late final _search = TextEditingController(text: widget.initialQuery ?? '');
  CaseStatus? _status;
  Timer? _debounce;

  final _cases = <CaseItem>[];
  String? _nextCursor;
  bool _loading = true;
  bool _loadingMore = false;
  Object? _error;
  int _generation = 0; // ignores responses to superseded searches

  bool get _canEdit => AuthService.instance.user?.role.canEditCases ?? false;

  @override
  void initState() {
    super.initState();
    _load();
    if (widget.openNewCase && _canEdit) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _newCase());
    }
  }

  @override
  void didUpdateWidget(CasesScreen old) {
    super.didUpdateWidget(old);
    if (widget.initialQuery != old.initialQuery) {
      _search.text = widget.initialQuery ?? '';
      _load();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    final generation = more ? _generation : ++_generation;
    setState(() {
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
        _error = null;
      }
    });
    try {
      final page = await _api.cases(
        status: _status,
        query: _search.text,
        cursor: more ? _nextCursor : null,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        if (!more) _cases.clear();
        _cases.addAll(page.items);
        _nextCursor = page.nextCursor;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      if (more) {
        showError(context, e);
      } else {
        setState(() => _error = e);
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = _loadingMore = false);
      }
    }
  }

  void _onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _load);
  }

  Future<void> _newCase() async {
    final created = await showNewCaseDialog(context);
    if (created == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Case #${created.reference} created')),
    );
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final filtering = _search.text.trim().isNotEmpty || _status != null;

    final filters = Row(
      children: [
        Expanded(
          child: TextField(
            controller: _search,
            onChanged: _onSearchChanged,
            decoration: const InputDecoration(
              hintText: 'Search by title or reference...',
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
            onChanged: (v) {
              setState(() => _status = v);
              _load();
            },
          ),
        ),
      ],
    );

    Widget body;
    if (_error != null) {
      body = ErrorPanel(message: '$_error', onRetry: _load);
    } else if (_loading) {
      body = const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
      );
    } else if (_cases.isEmpty) {
      body = filtering
          ? const EmptyPanel(
              icon: Icons.search_off,
              title: 'No cases match your search.')
          : EmptyPanel(
              icon: Icons.folder_open_outlined,
              title: 'No cases yet',
              message: _canEdit
                  ? 'Create your first case to start collecting evidence.'
                  : 'Cases you are added to will appear here.',
            );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (wide) _CasesTable(_cases) else for (final c in _cases) _CaseCard(c),
          if (_nextCursor != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Center(
                child: OutlinedButton(
                  onPressed: _loadingMore ? null : () => _load(more: true),
                  child: Text(_loadingMore ? 'Loading…' : 'Load more'),
                ),
              ),
            ),
        ],
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Cases',
            subtitle: 'Manage and track all your cases',
            action: _canEdit
                ? FilledButton.icon(
                    style:
                        FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                    onPressed: _newCase,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('New Case'),
                  )
                : null,
          ),
          SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [filters, const SizedBox(height: 16), body],
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
              cell(const Text('Reference', style: header), 2),
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
                  cell(Text(c.reference, style: const TextStyle(fontSize: 13)), 2),
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
                    Text('Case #${item.reference}',
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
