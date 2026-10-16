import 'package:cross_file/cross_file.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/api_endpoints.dart';
import '../../core/evidence_api.dart';
import '../../core/formatters.dart';
import '../../core/mock_repository.dart';
import '../../core/models.dart';
import '../../widgets/page_header.dart';

// Must match the backend's allowlist and limit (Docs/backend_plan.md, Step 0).
const _allowedExtensions = [
  'pdf', 'docx', 'xlsx', 'csv', 'txt', 'jpg', 'jpeg', 'png', 'tif', 'tiff',
];
const _maxBytes = 25 * 1024 * 1024; // 25 MB, as stated in the drop zone

enum _EvidenceType { documents, images, other }

/// A file the user picked or dropped, with its upload progress.
class _PendingFile {
  _PendingFile(this.file, this.bytes);
  final XFile file;
  final int bytes;
  double progress = 0;
  bool done = false;
  String? error;

  String get name => file.name;
}

/// Uploads evidence to a case.
///
/// With the real API (`--dart-define=USE_API=true`) each file is uploaded in
/// three steps: POST /v1/cases/{caseId}/evidence/upload-url (endpoint 7)
/// returns a signed URL, the bytes are PUT straight to storage, then POST
/// /v1/cases/{caseId}/evidence/{evidenceId}/complete (endpoint 8) verifies
/// the file and queues processing. Without the flag it runs on mock data.
class EvidenceUploadScreen extends StatefulWidget {
  const EvidenceUploadScreen({super.key, this.initialCaseId});

  final String? initialCaseId;

  @override
  State<EvidenceUploadScreen> createState() => _EvidenceUploadScreenState();
}

class _EvidenceUploadScreenState extends State<EvidenceUploadScreen> {
  final _api = EvidenceApi();
  final _files = <_PendingFile>[];
  String? _caseId;
  // Required: nothing is pre-selected, the user (or the picked files) decide.
  final _types = <_EvidenceType>{};
  bool _showTypeError = false;
  bool _uploading = false;
  bool _dragging = false;

  // Real API only.
  List<CaseRef>? _apiCases;
  List<EvidenceItem> _apiRecent = const [];
  String? _loadError;

  @override
  void initState() {
    super.initState();
    if (ApiEndpoints.useApi) {
      _loadCases();
    } else {
      _caseId = widget.initialCaseId ?? MockRepository.instance.cases().first.id;
    }
  }

  Future<void> _loadCases() async {
    try {
      final cases = await _api.cases();
      if (!mounted) return;
      setState(() {
        _apiCases = cases;
        _loadError = null;
        final initial = cases.where((c) =>
            c.id == widget.initialCaseId || c.reference == widget.initialCaseId);
        _caseId = initial.isNotEmpty
            ? initial.first.id
            : (cases.isNotEmpty ? cases.first.id : null);
      });
      await _loadRecent();
    } catch (e) {
      if (mounted) setState(() => _loadError = e.toString());
    }
  }

  Future<void> _loadRecent() async {
    final caseId = _caseId;
    if (!ApiEndpoints.useApi || caseId == null) return;
    try {
      final recent = await _api.evidence(caseId);
      if (mounted && caseId == _caseId) setState(() => _apiRecent = recent);
    } catch (_) {
      // The list is secondary; upload errors are shown where they happen.
    }
  }

  void _toggleType(_EvidenceType t) => setState(() {
        if (!_types.remove(t)) _types.add(t);
        if (_types.isNotEmpty) _showTypeError = false;
      });

  /// Picking a file ticks its type, so mixed uploads are labelled for free.
  _EvidenceType _typeForFile(String name) =>
      switch (name.split('.').last.toLowerCase()) {
        'pdf' || 'docx' || 'xlsx' || 'csv' || 'txt' => _EvidenceType.documents,
        'jpg' || 'jpeg' || 'png' || 'tif' || 'tiff' => _EvidenceType.images,
        _ => _EvidenceType.other,
      };

  Future<void> _browse() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: _allowedExtensions,
    );
    if (picked.isEmpty || !mounted) return;
    await _addFiles([for (final f in picked) f.xFile]);
  }

  /// Shared by the file picker and drag and drop: the same type and size
  /// checks apply however a file arrives.
  Future<void> _addFiles(List<XFile> incoming) async {
    final unsupported = <String>[];
    final tooBig = <String>[];
    for (final f in incoming) {
      final ext = f.name.split('.').last.toLowerCase();
      if (!f.name.contains('.') || !_allowedExtensions.contains(ext)) {
        unsupported.add(f.name);
        continue;
      }
      final size = await f.length();
      if (size > _maxBytes) {
        tooBig.add(f.name);
      } else if (!_files.any((p) => p.name == f.name && p.bytes == size)) {
        _files.add(_PendingFile(f, size));
        _types.add(_typeForFile(f.name));
      }
    }
    if (!mounted) return;
    setState(() {
      if (_types.isNotEmpty) _showTypeError = false;
    });
    final problems = [
      if (unsupported.isNotEmpty) 'Not supported: ${unsupported.join(', ')}',
      if (tooBig.isNotEmpty) 'Over 25 MB, not added: ${tooBig.join(', ')}',
    ];
    if (problems.isNotEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(problems.join('\n'))));
    }
  }

  Future<void> _upload() async {
    if (_types.isEmpty) {
      setState(() => _showTypeError = true);
      return;
    }
    final caseId = _caseId;
    if (caseId == null) return;
    setState(() => _uploading = true);
    var uploaded = 0;
    for (final f in _files.where((f) => !f.done).toList()) {
      setState(() {
        f.error = null;
        f.progress = 0.05;
      });
      try {
        if (ApiEndpoints.useApi) {
          await _api.upload(
            caseId: caseId,
            fileName: f.name,
            bytes: await f.file.readAsBytes(),
            evidenceTypes: [for (final t in _types) t.name],
            onStep: (v) {
              if (mounted) setState(() => f.progress = v);
            },
          );
        } else {
          await _simulateUpload(f, caseId);
        }
        f.done = true;
        uploaded++;
      } catch (e) {
        if (!mounted) return;
        setState(() {
          f.error = e.toString();
          f.progress = 0;
        });
      }
      if (!mounted) return;
    }
    setState(() {
      _uploading = false;
      _files.removeWhere((f) => f.done);
    });
    await _loadRecent();
    if (!mounted || uploaded == 0) return;
    final label = _caseLabel(caseId);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(_files.isEmpty
          ? 'Uploaded to $label. Processing has started.'
          : 'Uploaded $uploaded file${uploaded == 1 ? '' : 's'} to $label. '
              '${_files.length} failed; see the list.'),
    ));
  }

  Future<void> _simulateUpload(_PendingFile f, String caseId) async {
    for (var step = 1; step <= 10; step++) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      if (!mounted) return;
      setState(() => f.progress = step / 10);
    }
    MockRepository.instance.addEvidence(EvidenceFile(
      name: f.name,
      sizeLabel: _formatBytes(f.bytes),
      type: f.name.split('.').last.toUpperCase(),
      uploadedAt: DateTime.now(),
      caseId: caseId,
    ));
  }

  String _caseLabel(String caseId) {
    final match = _apiCases?.where((c) => c.id == caseId);
    return match != null && match.isNotEmpty
        ? 'Case #${match.first.reference}'
        : 'Case #$caseId';
  }

  List<DropdownMenuItem<String>> _caseItems() => ApiEndpoints.useApi
      ? [
          for (final c in _apiCases ?? const <CaseRef>[])
            DropdownMenuItem(
              value: c.id,
              child: Text('Case #${c.reference} - ${c.title}'),
            ),
        ]
      : [
          for (final c in MockRepository.instance.cases())
            DropdownMenuItem(
              value: c.id,
              child: Text('Case #${c.id} - ${c.title}'),
            ),
        ];

  Widget _caseField() {
    if (ApiEndpoints.useApi && _loadError != null) {
      return Row(
        children: [
          Expanded(
            child: Text("Couldn't load cases: $_loadError",
                style: const TextStyle(fontSize: 13, color: AppColors.danger)),
          ),
          TextButton(onPressed: _loadCases, child: const Text('Retry')),
        ],
      );
    }
    if (ApiEndpoints.useApi && _apiCases == null) {
      return const LinearProgressIndicator(minHeight: 2);
    }
    if (ApiEndpoints.useApi && _apiCases!.isEmpty) {
      return const Text('No cases yet. Create a case first.',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary));
    }
    return DropdownButtonFormField<String>(
      initialValue: _caseId,
      isExpanded: true,
      items: _caseItems(),
      onChanged: _uploading
          ? null
          : (v) {
              setState(() => _caseId = v);
              _loadRecent();
            },
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 1100;

    final form = SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropTarget(
            enable: !_uploading,
            onDragEntered: (_) => setState(() => _dragging = true),
            onDragExited: (_) => setState(() => _dragging = false),
            onDragDone: (details) {
              setState(() => _dragging = false);
              _addFiles(details.files);
            },
            child: _DropZone(
              onTap: _uploading ? null : _browse,
              highlighted: _dragging,
            ),
          ),
          if (_files.isNotEmpty) ...[
            const SizedBox(height: 16),
            for (final f in _files)
              _PendingRow(
                file: f,
                onRemove: _uploading ? null : () => setState(() => _files.remove(f)),
              ),
          ],
          const SizedBox(height: 20),
          const Text('Upload to Case',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
          const SizedBox(height: 6),
          _caseField(),
          const SizedBox(height: 20),
          const Text.rich(
            TextSpan(
              text: 'Evidence Type ',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
              children: [
                TextSpan(text: '*', style: TextStyle(color: AppColors.danger)),
              ],
            ),
            semanticsLabel: 'Evidence Type, required',
          ),
          const SizedBox(height: 8),
          // Several types can be ticked, since one upload may mix them.
          Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              for (final t in _EvidenceType.values)
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: _uploading ? null : () => _toggleType(t),
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          value: _types.contains(t),
                          onChanged: _uploading ? null : (_) => _toggleType(t),
                        ),
                        Text(switch (t) {
                          _EvidenceType.documents => 'Documents',
                          _EvidenceType.images => 'Images',
                          _EvidenceType.other => 'Other',
                        }),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          if (_showTypeError)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('Select at least one evidence type',
                  style: TextStyle(fontSize: 12, color: AppColors.danger)),
            ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed:
                _files.isEmpty || _uploading || _caseId == null ? null : _upload,
            child: Text(_uploading
                ? 'Uploading…'
                : _files.isEmpty
                    ? 'Upload Files'
                    : 'Upload ${_files.length} file${_files.length == 1 ? '' : 's'}'),
          ),
        ],
      ),
    );

    final recent = SectionCard(
      title: 'Recent Uploads',
      child: Column(
        children: [
          if (ApiEndpoints.useApi)
            for (final e in _apiRecent)
              _RecentRow(
                name: e.fileName,
                type: e.fileName.split('.').last.toUpperCase(),
                detail: '${_formatBytes(e.sizeBytes)} · ${_statusLabel(e)}',
                at: e.createdAt,
              )
          else
            for (final e in MockRepository.instance.recentEvidence().take(6))
              _RecentRow(
                name: e.name,
                type: e.type,
                detail: '${e.sizeLabel} · ${e.type}',
                at: e.uploadedAt,
              ),
        ],
      ),
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(
            title: 'Upload Evidence',
            subtitle: 'Add files, documents, or media to your case',
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
            form,
            const SizedBox(height: 16),
            recent,
          ],
        ],
      ),
    );
  }
}

String _statusLabel(EvidenceItem e) => switch (e.status) {
      'queued' || 'extracting' || 'grounding' || 'reconciling' => 'Processing',
      'processed' => 'Processed',
      'needs_review' => 'Needs review',
      'failed_terminal' || 'failed_retryable' => 'Failed',
      _ => 'Uploading',
    };

class _DropZone extends StatelessWidget {
  const _DropZone({required this.onTap, this.highlighted = false});
  final VoidCallback? onTap;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 16),
        decoration: BoxDecoration(
          color: AppColors.primarySoft
              .withValues(alpha: highlighted ? 0.9 : 0.4),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: AppColors.primary.withValues(alpha: highlighted ? 1 : 0.35),
            width: highlighted ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            const Icon(Icons.cloud_upload_outlined,
                size: 40, color: AppColors.primary),
            const SizedBox(height: 12),
            Text(highlighted ? 'Drop to add files' : 'Drag and drop files here',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            const Text('or click to browse',
                style: TextStyle(color: AppColors.primary, fontSize: 13)),
            const SizedBox(height: 8),
            const Text(
                'Supports: PDF, DOCX, XLSX, CSV, TXT, JPG, PNG, TIFF (Max 25MB)',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          ],
        ),
      ),
    );
  }
}

class _PendingRow extends StatelessWidget {
  const _PendingRow({required this.file, required this.onRemove});
  final _PendingFile file;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          _FileIcon(file.name.split('.').last.toUpperCase()),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(file.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13)),
                const SizedBox(height: 4),
                LinearProgressIndicator(
                  value: file.progress,
                  minHeight: 4,
                  borderRadius: BorderRadius.circular(2),
                  backgroundColor: AppColors.border,
                ),
                if (file.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(file.error!,
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.danger)),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(_formatBytes(file.bytes),
              style:
                  const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          IconButton(
            tooltip: 'Remove',
            icon: const Icon(Icons.close, size: 18),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

class _RecentRow extends StatelessWidget {
  const _RecentRow({
    required this.name,
    required this.type,
    required this.detail,
    required this.at,
  });
  final String name;
  final String type;
  final String detail;
  final DateTime at;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          _FileIcon(type),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w500)),
                Text(detail,
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textSecondary)),
              ],
            ),
          ),
          Text(timeAgo(at),
              style:
                  const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}

class _FileIcon extends StatelessWidget {
  const _FileIcon(this.type);
  final String type;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (type) {
      'PDF' => (Icons.picture_as_pdf_outlined, AppColors.danger),
      'JPG' || 'JPEG' || 'PNG' => (Icons.image_outlined, AppColors.success),
      'MP4' => (Icons.movie_outlined, AppColors.primary),
      'XLSX' => (Icons.table_chart_outlined, AppColors.success),
      _ => (Icons.insert_drive_file_outlined, AppColors.textSecondary),
    };
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, size: 18, color: color),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024).ceil()} KB';
}
