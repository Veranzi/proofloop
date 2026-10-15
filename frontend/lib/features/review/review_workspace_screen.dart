import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/auth_service.dart';
import '../../core/formatters.dart';
import '../../core/mock_repository.dart';
import '../../core/models.dart';
import '../../widgets/page_header.dart';
import '../../widgets/status_chip.dart';

class _Note {
  const _Note(this.author, this.text, this.at);
  final String author;
  final String text;
  final DateTime at;
}

/// Where a reviewer checks the evidence and records the human decision.
///
/// AI output is only ever shown as extracted text with its source; the
/// decision itself is always made here by a person
/// (POST /v1/cases/{caseId}/findings/{findingId}/decision, endpoint 15).
class ReviewWorkspaceScreen extends StatefulWidget {
  const ReviewWorkspaceScreen({super.key, this.initialCaseId});

  final String? initialCaseId;

  @override
  State<ReviewWorkspaceScreen> createState() => _ReviewWorkspaceScreenState();
}

class _ReviewWorkspaceScreenState extends State<ReviewWorkspaceScreen> {
  final _noteController = TextEditingController();
  final _notes = <_Note>[];
  late CaseItem _case;
  ReviewDecision? _decision;
  String? _savedSummary;

  @override
  void initState() {
    super.initState();
    final repo = MockRepository.instance;
    _case = (widget.initialCaseId != null
            ? repo.caseById(widget.initialCaseId!)
            : null) ??
        repo.cases().firstWhere((c) => c.status == CaseStatus.inReview,
            orElse: () => repo.cases().first);
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  void _addNote() {
    final text = _noteController.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _notes.insert(0, _Note(AuthService.instance.user?.name ?? 'You', text,
          DateTime.now()));
      _noteController.clear();
    });
  }

  void _saveDecision() {
    if (_decision == null) return;
    // Reject and "needs more info" must explain why, for the audit trail.
    if (_decision != ReviewDecision.approve && _notes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Add a note explaining this decision first.'),
      ));
      return;
    }
    final who = AuthService.instance.user?.name ?? 'You';
    setState(() => _savedSummary =
        '${_decisionLabel(_decision!)} by $who · ${formatDateTime(DateTime.now())}');
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Decision saved')));
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
                onChanged: (c) => setState(() {
                  _case = c;
                  _decision = null;
                  _savedSummary = null;
                  _notes.clear();
                }),
              ),
            ),
            const TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                Tab(text: 'Evidence'),
                Tab(text: 'Notes'),
                Tab(text: 'Timeline'),
              ],
            ),
            const Divider(height: 1),
            SizedBox(
              height: 520,
              child: TabBarView(
                children: [
                  _EvidencePreview(caseId: _case.id),
                  _NotesList(_notes),
                  _ReviewTimeline(item: _case, saved: _savedSummary),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    final side = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionCard(
          title: 'Review Decision',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final d in ReviewDecision.values)
                _DecisionOption(
                  label: _decisionLabel(d),
                  selected: _decision == d,
                  onTap: () => setState(() => _decision = d),
                ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _decision == null ? null : _saveDecision,
                child: const Text('Save Decision'),
              ),
              if (_savedSummary != null) ...[
                const SizedBox(height: 10),
                Text(_savedSummary!,
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.success)),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Add Notes',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _noteController,
                maxLines: 4,
                decoration:
                    const InputDecoration(hintText: 'Add your notes here...'),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size(110, 40)),
                  onPressed: _addNote,
                  child: const Text('Add Note'),
                ),
              ),
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
          const PageHeader(
            title: 'Review Workspace',
            subtitle: 'Analyze evidence, add notes and make a decision',
          ),
          if (wide)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: main),
                const SizedBox(width: 20),
                SizedBox(width: 320, child: side),
              ],
            )
          else ...[
            main,
            const SizedBox(height: 16),
            side,
          ],
        ],
      ),
    );
  }
}

String _decisionLabel(ReviewDecision d) => switch (d) {
      ReviewDecision.approve => 'Approve',
      ReviewDecision.reject => 'Reject',
      ReviewDecision.needsMoreInfo => 'Needs More Info',
    };

class _CaseHeader extends StatelessWidget {
  const _CaseHeader({required this.item, required this.onChanged});
  final CaseItem item;
  final ValueChanged<CaseItem> onChanged;

  @override
  Widget build(BuildContext context) {
    final cases = MockRepository.instance.cases();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Case #${item.id}',
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
              PopupMenuItem(value: c, child: Text('#${c.id} ${c.title}')),
          ],
        ),
      ],
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

/// Mock document page. With the API this renders the evidence through a
/// signed view URL (endpoint 11) and draws Document AI bounding boxes
/// (endpoint 12) over the cited span.
class _EvidencePreview extends StatelessWidget {
  const _EvidencePreview({required this.caseId});
  final String caseId;

  @override
  Widget build(BuildContext context) {
    final files = MockRepository.instance
        .recentEvidence()
        .where((e) => e.caseId == caseId)
        .toList();
    final fileName = files.isEmpty ? 'contract.pdf' : files.first.name;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.picture_as_pdf_outlined,
                  color: AppColors.danger, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(fileName,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w500)),
              ),
              const SizedBox(width: 8),
              const Text('Page 1 of 3',
                  style:
                      TextStyle(fontSize: 12, color: AppColors.textSecondary)),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.border),
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < 5; i++) const _TextLine(),
                    const SizedBox(height: 8),
                    // Highlighted span the extracted claim points to.
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFD54F).withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text('Total due: 1,250.00',
                          style: TextStyle(fontStyle: FontStyle.italic)),
                    ),
                    const SizedBox(height: 8),
                    for (var i = 0; i < 6; i++) const _TextLine(),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          const _ExtractedClaim(),
        ],
      ),
    );
  }
}

class _TextLine extends StatelessWidget {
  const _TextLine();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 8,
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppColors.border,
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}

/// An AI-extracted value, labelled as such, with its quoted source.
class _ExtractedClaim extends StatelessWidget {
  const _ExtractedClaim();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFF6B4FA0).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text('AI-extracted',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF6B4FA0))),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text('Invoice total: 1,250.00 · page 1, highlighted above',
                style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }
}

class _NotesList extends StatelessWidget {
  const _NotesList(this.notes);
  final List<_Note> notes;

  @override
  Widget build(BuildContext context) {
    if (notes.isEmpty) {
      return const Center(
        child: Text('No notes yet. Add one from the panel.',
            style: TextStyle(color: AppColors.textSecondary)),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(20),
      itemCount: notes.length,
      separatorBuilder: (_, _) => const Divider(),
      itemBuilder: (_, i) => ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(notes[i].text),
        subtitle: Text('${notes[i].author} · ${timeAgo(notes[i].at)}'),
      ),
    );
  }
}

class _ReviewTimeline extends StatelessWidget {
  const _ReviewTimeline({required this.item, required this.saved});
  final CaseItem item;
  final String? saved;

  @override
  Widget build(BuildContext context) {
    final entries = [
      if (saved != null) 'Decision: $saved',
      'Evidence processed and claims extracted',
      'Case opened by ${item.assignedTo} · ${formatDateTime(item.createdAt)}',
    ];
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        for (final e in entries)
          ListTile(
            contentPadding: EdgeInsets.zero,
            minLeadingWidth: 16,
            leading:
                const Icon(Icons.circle, size: 10, color: AppColors.primary),
            title: Text(e, style: const TextStyle(fontSize: 14)),
          ),
      ],
    );
  }
}
