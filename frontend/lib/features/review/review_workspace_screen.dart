import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/api.dart';
import '../../core/auth_service.dart';
import '../../core/download.dart';
import '../../core/formatters.dart';
import '../../core/models.dart';
import '../../widgets/async_view.dart';
import '../../widgets/page_header.dart';
import '../../widgets/status_chip.dart';
import '../cases/case_details_screen.dart' show TimelineList;

/// Where a reviewer checks each finding against its evidence and records the
/// human decision.
///
/// Findings come from the rule engine (GET .../findings, endpoint 14). AI
/// output is only ever shown as extracted values with their source; the
/// decision is always made here by a person
/// (POST /v1/cases/{caseId}/findings/{findingId}/decision, endpoint 15).
class ReviewWorkspaceScreen extends StatefulWidget {
  const ReviewWorkspaceScreen({super.key, this.initialCaseId});

  final String? initialCaseId;

  @override
  State<ReviewWorkspaceScreen> createState() => _ReviewWorkspaceScreenState();
}

class _ReviewWorkspaceScreenState extends State<ReviewWorkspaceScreen> {
  final _api = PrufloApi();
  late Future<List<CaseItem>> _cases = _loadCases();
  CaseItem? _case;

  Future<List<CaseItem>> _loadCases() async {
    final (cases, _) = await _api.allCases(cap: 500);
    if (_case == null && cases.isNotEmpty) {
      final wanted = cases.where((c) =>
          c.id == widget.initialCaseId || c.reference == widget.initialCaseId);
      final inReview = cases.where((c) => c.status == CaseStatus.inReview);
      _case = wanted.isNotEmpty
          ? wanted.first
          : (inReview.isNotEmpty ? inReview.first : cases.first);
    }
    return cases;
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(
            title: 'Review Workspace',
            subtitle: 'Check each finding against its evidence and decide',
          ),
          AsyncView<List<CaseItem>>(
            future: _cases,
            onRetry: () => setState(() { _cases = _loadCases(); }),
            builder: (context, cases) {
              final selected = _case;
              if (cases.isEmpty || selected == null) {
                return const SectionCard(
                  child: EmptyPanel(
                    icon: Icons.fact_check_outlined,
                    title: 'No cases to review',
                    message: 'Cases you can access will appear here.',
                  ),
                );
              }
              return _CaseReview(
                key: ValueKey(selected.id),
                item: selected,
                cases: cases,
                onSwitch: (c) => setState(() => _case = c),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// The review of one case: its findings, the decision panel, notes and
/// timeline.
class _CaseReview extends StatefulWidget {
  const _CaseReview({
    super.key,
    required this.item,
    required this.cases,
    required this.onSwitch,
  });

  final CaseItem item;
  final List<CaseItem> cases;
  final ValueChanged<CaseItem> onSwitch;

  @override
  State<_CaseReview> createState() => _CaseReviewState();
}

class _CaseReviewState extends State<_CaseReview> {
  final _api = PrufloApi();
  late CaseItem _case = widget.item;
  late Future<List<Finding>> _findingsFuture = _loadFindings();
  List<Finding> _findings = const [];
  String? _selectedId;
  int _timelineVersion = 0;

  Future<List<Finding>> _loadFindings() async {
    final findings = await _api.findings(_case.id);
    _findings = findings;
    if (_selectedId == null || !findings.any((f) => f.id == _selectedId)) {
      final pending =
          findings.where((f) => f.review.status == ReviewDecision.pending);
      _selectedId = (pending.isNotEmpty ? pending.first : findings.firstOrNull)
          ?.id;
    }
    // The decision panel and notes sit outside the list's FutureBuilder.
    if (mounted) setState(() {});
    return findings;
  }

  Finding? get _selected =>
      _findings.where((f) => f.id == _selectedId).firstOrNull;

  /// After a decision: refresh the finding, the case status and the timeline.
  Future<void> _decided(Finding updated) async {
    setState(() {
      _findings = [
        for (final f in _findings) f.id == updated.id ? updated : f,
      ];
      _findingsFuture = Future.value(_findings);
      _timelineVersion++;
    });
    try {
      final fresh = await _api.getCase(_case.id);
      if (mounted) setState(() => _case = fresh);
    } catch (_) {
      // The decision is saved; the status chip catches up on the next visit.
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 1100;

    final main = SectionCard(
      padding: EdgeInsets.zero,
      child: DefaultTabController(
        length: 3,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: _CaseHeader(
                item: _case,
                cases: widget.cases,
                onChanged: widget.onSwitch,
              ),
            ),
            const TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                Tab(text: 'Findings'),
                Tab(text: 'Notes'),
                Tab(text: 'Timeline'),
              ],
            ),
            const Divider(height: 1),
            SizedBox(
              height: 520,
              child: TabBarView(
                children: [
                  AsyncView<List<Finding>>(
                    future: _findingsFuture,
                    onRetry: () =>
                        setState(() { _findingsFuture = _loadFindings(); }),
                    builder: (context, findings) => _FindingsList(
                      caseId: _case.id,
                      findings: findings,
                      selectedId: _selectedId,
                      onSelect: (f) => setState(() => _selectedId = f.id),
                    ),
                  ),
                  _NotesList(_findings),
                  _Timeline(
                      key: ValueKey(_timelineVersion), caseId: _case.id),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    final side = _DecisionPanel(
      key: ValueKey(_selected?.id),
      caseId: _case.id,
      finding: _selected,
      onDecided: _decided,
    );

    if (!wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [main, const SizedBox(height: 16), side],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 3, child: main),
        const SizedBox(width: 20),
        SizedBox(width: 340, child: side),
      ],
    );
  }
}

String _decisionLabel(ReviewDecision d) => switch (d) {
      ReviewDecision.approve => 'Approve',
      ReviewDecision.reject => 'Reject',
      ReviewDecision.pending => 'Pending',
    };

Widget _reviewPill(ReviewDecision d) => switch (d) {
      ReviewDecision.approve => const Pill('Approved',
          foreground: AppColors.success, background: AppColors.successSoft),
      ReviewDecision.reject => const Pill('Rejected',
          foreground: AppColors.danger, background: AppColors.dangerSoft),
      ReviewDecision.pending => const Pill('Pending',
          foreground: AppColors.warning, background: AppColors.warningSoft),
    };

Widget _severityPill(String severity) => switch (severity) {
      'high' => const Pill('High',
          foreground: AppColors.danger, background: AppColors.dangerSoft),
      'low' => const Pill('Low',
          foreground: AppColors.success, background: AppColors.successSoft),
      _ => const Pill('Medium',
          foreground: AppColors.warning, background: AppColors.warningSoft),
    };

class _CaseHeader extends StatelessWidget {
  const _CaseHeader({
    required this.item,
    required this.cases,
    required this.onChanged,
  });
  final CaseItem item;
  final List<CaseItem> cases;
  final ValueChanged<CaseItem> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Case #${item.reference}',
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textSecondary)),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(item.title,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600)),
                  StatusChip(item.status),
                  PriorityChip(item.priority),
                ],
              ),
            ],
          ),
        ),
        PopupMenuButton<CaseItem>(
          tooltip: 'Switch case',
          icon: const Icon(Icons.swap_horiz),
          onSelected: onChanged,
          itemBuilder: (_) => [
            for (final c in cases)
              PopupMenuItem(
                value: c,
                child: Text('#${c.reference} ${c.title}',
                    overflow: TextOverflow.ellipsis),
              ),
          ],
        ),
      ],
    );
  }
}

class _FindingsList extends StatelessWidget {
  const _FindingsList({
    required this.caseId,
    required this.findings,
    required this.selectedId,
    required this.onSelect,
  });

  final String caseId;
  final List<Finding> findings;
  final String? selectedId;
  final ValueChanged<Finding> onSelect;

  @override
  Widget build(BuildContext context) {
    if (findings.isEmpty) {
      return const EmptyPanel(
        icon: Icons.fact_check_outlined,
        title: 'No findings yet',
        message: 'Findings appear after the evidence is processed and '
            'reconciled.',
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final f in findings)
          _FindingCard(
            caseId: caseId,
            finding: f,
            selected: f.id == selectedId,
            onTap: () => onSelect(f),
          ),
      ],
    );
  }
}

class _FindingCard extends StatelessWidget {
  const _FindingCard({
    required this.caseId,
    required this.finding,
    required this.selected,
    required this.onTap,
  });

  final String caseId;
  final Finding finding;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final f = finding;
    Widget value(String label, Quantity? q) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(
                      fontSize: 11, color: AppColors.textSecondary)),
              Text(q?.toString() ?? '—',
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
            ],
          ),
        );

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
            color: selected ? AppColors.primary : AppColors.border,
            width: selected ? 2 : 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(f.title,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  _severityPill(f.severity),
                  _reviewPill(f.review.status),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  value('Expected', f.expected),
                  value('Observed', f.observed),
                  value('Difference', f.difference),
                ],
              ),
              if (selected) ...[
                if (f.explanation.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _SourceLabel(machine: f.explanationSource == 'machine_generated'),
                  const SizedBox(height: 4),
                  Text(f.explanation, style: const TextStyle(fontSize: 13)),
                ],
                const SizedBox(height: 12),
                const Text('Cited evidence',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary)),
                if (f.evidence.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text('No cited evidence.',
                        style: TextStyle(
                            fontSize: 13, color: AppColors.textSecondary)),
                  ),
                for (final c in f.evidence) _ClaimRow(caseId: caseId, claim: c),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Labels where a sentence came from, so model output is never mistaken
/// for a rule result.
class _SourceLabel extends StatelessWidget {
  const _SourceLabel({required this.machine});
  final bool machine;

  @override
  Widget build(BuildContext context) {
    const purple = Color(0xFF6B4FA0);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: (machine ? purple : AppColors.primary).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(machine ? 'Machine-generated' : 'From the rule',
          style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: machine ? purple : AppColors.primary)),
    );
  }
}

/// A value read from a document, with its quote and a link to the source.
class _ClaimRow extends StatelessWidget {
  const _ClaimRow({required this.caseId, required this.claim});
  final String caseId;
  final Claim claim;

  Future<void> _view(BuildContext context) async {
    try {
      await openUrl(
          await PrufloApi().evidenceViewUrl(caseId, claim.evidenceId));
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final grounded = claim.grounding == 'grounded';
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    '${claim.fieldLabel}: ${claim.value}'
                    '${claim.unit.isEmpty ? '' : ' ${claim.unit}'}',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w500)),
                if (claim.quote.isNotEmpty)
                  Text('"${claim.quote}"',
                      style: const TextStyle(
                          fontSize: 12, fontStyle: FontStyle.italic)),
                const SizedBox(height: 2),
                Text(
                    '${claim.fileName}'
                    '${claim.page == null ? '' : ' · page ${claim.page}'}'
                    ' · ${grounded ? 'source found' : 'check the source'}',
                    style: TextStyle(
                        fontSize: 12,
                        color: grounded
                            ? AppColors.textSecondary
                            : AppColors.warning)),
              ],
            ),
          ),
          TextButton(
            onPressed: () => _view(context),
            child: const Text('View source'),
          ),
        ],
      ),
    );
  }
}

class _DecisionPanel extends StatefulWidget {
  const _DecisionPanel({
    super.key,
    required this.caseId,
    required this.finding,
    required this.onDecided,
  });

  final String caseId;
  final Finding? finding;
  final ValueChanged<Finding> onDecided;

  @override
  State<_DecisionPanel> createState() => _DecisionPanelState();
}

class _DecisionPanelState extends State<_DecisionPanel> {
  final _note = TextEditingController();
  ReviewDecision? _decision;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final finding = widget.finding;
    final decision = _decision;
    if (finding == null || decision == null) return;
    // Reject and pending must explain why, for the audit trail.
    if (decision != ReviewDecision.approve && _note.text.trim().isEmpty) {
      setState(() => _error = 'Add a note explaining this decision first.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final updated = await PrufloApi()
          .decide(widget.caseId, finding.id, decision, _note.text.trim());
      if (!mounted) return;
      _note.clear();
      setState(() => _decision = null);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Decision saved')));
      widget.onDecided(updated);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final finding = widget.finding;
    final canDecide = AuthService.instance.user?.role.canDecide ?? false;

    if (finding == null) {
      return const SectionCard(
        title: 'Review Decision',
        child: Text('Select a finding to review it.',
            style: TextStyle(color: AppColors.textSecondary)),
      );
    }
    final review = finding.review;
    return SectionCard(
      title: 'Review Decision',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(finding.title,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Row(children: [
            _reviewPill(review.status),
            const SizedBox(width: 8),
            if (review.by != null && review.at != null)
              Expanded(
                child: Text(
                    'by ${review.by!.name} · ${formatDateTime(review.at!)}',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textSecondary)),
              ),
          ]),
          if (review.note.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('"${review.note}"',
                style: const TextStyle(
                    fontSize: 12, fontStyle: FontStyle.italic)),
          ],
          const Divider(height: 24),
          if (!canDecide)
            const Text(
              'Only reviewers and admins can record decisions.',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
            )
          else ...[
            for (final d in ReviewDecision.values)
              _DecisionOption(
                label: _decisionLabel(d),
                selected: _decision == d,
                onTap: () => setState(() {
                  _decision = d;
                  _error = null;
                }),
              ),
            const SizedBox(height: 8),
            TextField(
              controller: _note,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: _decision == null ||
                        _decision == ReviewDecision.approve
                    ? 'Note (optional for approve)'
                    : 'Why? (required)',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style:
                      const TextStyle(fontSize: 12, color: AppColors.danger)),
            ],
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _decision == null || _saving ? null : _save,
              child: Text(_saving ? 'Saving…' : 'Save Decision'),
            ),
          ],
        ],
      ),
    );
  }
}

class _DecisionOption extends StatelessWidget {
  const _DecisionOption({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Row(
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 20,
                color: selected ? AppColors.primary : AppColors.textSecondary,
              ),
              const SizedBox(width: 10),
              Text(label),
            ],
          ),
        ),
      ),
    );
  }
}

/// Notes are the reasons people gave with their decisions; they live in the
/// audit trail with the decision.
class _NotesList extends StatelessWidget {
  const _NotesList(this.findings);
  final List<Finding> findings;

  @override
  Widget build(BuildContext context) {
    final notes = [
      for (final f in findings)
        if (f.review.note.isNotEmpty) f,
    ];
    if (notes.isEmpty) {
      return const EmptyPanel(
        icon: Icons.notes_outlined,
        title: 'No notes yet',
        message: 'Notes added with decisions appear here.',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(20),
      itemCount: notes.length,
      separatorBuilder: (_, _) => const Divider(),
      itemBuilder: (_, i) {
        final f = notes[i];
        final by = f.review.by?.name ?? '';
        final at = f.review.at;
        return ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(f.review.note),
          subtitle: Text([
            '${f.title} · ${_decisionLabel(f.review.status)}',
            if (by.isNotEmpty) by,
            if (at != null) timeAgo(at),
          ].join(' · ')),
        );
      },
    );
  }
}

class _Timeline extends StatefulWidget {
  const _Timeline({super.key, required this.caseId});
  final String caseId;

  @override
  State<_Timeline> createState() => _TimelineState();
}

class _TimelineState extends State<_Timeline> {
  late Future<List<TimelineItem>> _future = PrufloApi().timeline(widget.caseId);

  @override
  Widget build(BuildContext context) {
    return AsyncView<List<TimelineItem>>(
      future: _future,
      onRetry: () =>
          setState(() { _future = PrufloApi().timeline(widget.caseId); }),
      builder: (context, events) => events.isEmpty
          ? const EmptyPanel(title: 'Nothing has happened yet.')
          : TimelineList(events, padding: const EdgeInsets.all(20)),
    );
  }
}
