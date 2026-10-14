import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/formatters.dart';
import '../../core/mock_repository.dart';
import '../../core/models.dart';
import '../../widgets/page_header.dart';

enum _ReportType { summary, detailed, executive }

/// Generate a case report and list recent ones.
///
/// API: POST /v1/cases/{caseId}/reports (17) starts generation,
/// GET .../reports (18) lists them, and GET .../download-url (19) returns a
/// signed URL for the PDF.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key, this.initialCaseId});

  final String? initialCaseId;

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  late String _caseId;
  _ReportType _type = _ReportType.detailed;
  final _sections = <String, bool>{
    'Evidence Summary': true,
    'Timeline': true,
    'Findings & Conclusion': true,
    'Recommendations': true,
  };
  bool _generating = false;

  @override
  void initState() {
    super.initState();
    _caseId = widget.initialCaseId ?? MockRepository.instance.cases().first.id;
  }

  Future<void> _generate() async {
    final repo = MockRepository.instance;
    final item = repo.caseById(_caseId)!;
    setState(() => _generating = true);
    await Future<void>.delayed(const Duration(seconds: 1));
    repo.addReport(ReportItem(
      title: '${item.title} Report',
      caseId: item.id,
      createdAt: DateTime.now(),
    ));
    if (!mounted) return;
    setState(() => _generating = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Report for Case #${item.id} is ready'),
    ));
  }

  void _download(ReportItem r) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Downloading ${r.title}.pdf'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 1100;
    final cases = MockRepository.instance.cases();
    final anySection = _sections.values.any((v) => v);

    final form = SectionCard(
      title: 'Generate Report',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Label('Case'),
          DropdownButtonFormField<String>(
            initialValue: _caseId,
            isExpanded: true,
            items: [
              for (final c in cases)
                DropdownMenuItem(
                    value: c.id, child: Text('Case #${c.id} - ${c.title}')),
            ],
            onChanged: (v) => setState(() => _caseId = v!),
          ),
          const SizedBox(height: 20),
          const _Label('Report Type'),
          for (final t in _ReportType.values)
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => _type = t),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(
                      _type == t
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      size: 20,
                      color: _type == t
                          ? AppColors.primary
                          : AppColors.textSecondary,
                    ),
                    const SizedBox(width: 10),
                    Text(switch (t) {
                      _ReportType.summary => 'Summary Report',
                      _ReportType.detailed => 'Detailed Report',
                      _ReportType.executive => 'Executive Report',
                    }),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 16),
          const _Label('Include'),
          for (final entry in _sections.entries)
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: entry.value,
              title: Text(entry.key),
              onChanged: (v) => setState(() => _sections[entry.key] = v!),
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _generating || !anySection ? null : _generate,
            child: Text(_generating ? 'Generating…' : 'Generate Report'),
          ),
        ],
      ),
    );

    final recent = SectionCard(
      title: 'Recent Reports',
      child: Column(
        children: [
          for (final r in MockRepository.instance.reports())
            _ReportRow(report: r, onDownload: () => _download(r)),
        ],
      ),
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: wide ? 'Generate Report' : 'Reports',
            subtitle: 'Create detailed reports from your case analysis',
          ),
          if (wide)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: form),
                const SizedBox(width: 20),
                Expanded(flex: 2, child: recent),
              ],
            )
          else ...[
            // Phones lead with the report list, as in the mobile mockup.
            recent,
            const SizedBox(height: 16),
            form,
          ],
        ],
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
    );
  }
}

class _ReportRow extends StatelessWidget {
  const _ReportRow({required this.report, required this.onDownload});
  final ReportItem report;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onDownload,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppColors.dangerSoft,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.picture_as_pdf_outlined,
                  size: 18, color: AppColors.danger),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(report.title,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                  Text('Case #${report.caseId} · PDF',
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textSecondary)),
                ],
              ),
            ),
            Text(timeAgo(report.createdAt),
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textSecondary)),
            IconButton(
              tooltip: 'Download PDF',
              icon: const Icon(Icons.download_outlined, size: 18),
              onPressed: onDownload,
            ),
          ],
        ),
      ),
    );
  }
}
