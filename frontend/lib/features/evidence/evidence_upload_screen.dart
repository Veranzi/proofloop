import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/formatters.dart';
import '../../core/mock_repository.dart';
import '../../core/models.dart';
import '../../widgets/page_header.dart';

const _allowedExtensions = ['pdf', 'jpg', 'jpeg', 'png', 'mp4', 'docx', 'xlsx'];
const _maxBytes = 100 * 1024 * 1024; // 100 MB, as stated in the drop zone

enum _EvidenceType { documents, images, videos, other }

/// A file the user picked, with its upload progress.
class _PendingFile {
  _PendingFile(this.name, this.bytes);
  final String name;
  final int bytes;
  double progress = 0;
  bool done = false;
}

/// Uploads evidence to a case.
///
/// With the real API each file is uploaded in two steps: POST
/// /v1/cases/{caseId}/evidence/upload-url (endpoint 7) returns a V4 signed
/// URL, then the bytes are PUT straight to Cloud Storage (endpoint 8). The
/// upload-complete event queues processing through Pub/Sub.
class EvidenceUploadScreen extends StatefulWidget {
  const EvidenceUploadScreen({super.key, this.initialCaseId});

  final String? initialCaseId;

  @override
  State<EvidenceUploadScreen> createState() => _EvidenceUploadScreenState();
}

class _EvidenceUploadScreenState extends State<EvidenceUploadScreen> {
  final _files = <_PendingFile>[];
  late String _caseId;
  _EvidenceType _type = _EvidenceType.documents;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    final cases = MockRepository.instance.cases();
    _caseId = widget.initialCaseId ?? cases.first.id;
  }

  Future<void> _browse() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: _allowedExtensions,
    );
    if (picked.isEmpty || !mounted) return;

    final rejected = <String>[];
    for (final f in picked) {
      final size = await f.length() ?? 0;
      if (size > _maxBytes) {
        rejected.add(f.name);
      } else {
        _files.add(_PendingFile(f.name, size));
      }
    }
    if (!mounted) return;
    setState(() {});
    if (rejected.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Over 100 MB, not added: ${rejected.join(', ')}'),
      ));
    }
  }

  Future<void> _upload() async {
    setState(() => _uploading = true);
    for (final f in _files.where((f) => !f.done)) {
      // Simulated transfer; replace with the signed-URL PUT.
      for (var step = 1; step <= 10; step++) {
        await Future<void>.delayed(const Duration(milliseconds: 80));
        if (!mounted) return;
        setState(() => f.progress = step / 10);
      }
      f.done = true;
      MockRepository.instance.addEvidence(EvidenceFile(
        name: f.name,
        sizeLabel: _formatBytes(f.bytes),
        type: f.name.split('.').last.toUpperCase(),
        uploadedAt: DateTime.now(),
        caseId: _caseId,
      ));
    }
    if (!mounted) return;
    setState(() {
      _uploading = false;
      _files.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Uploaded to Case #$_caseId. Processing has started.'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 1100;
    final cases = MockRepository.instance.cases();

    final form = SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _DropZone(onTap: _uploading ? null : _browse),
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
          DropdownButtonFormField<String>(
            initialValue: _caseId,
            isExpanded: true,
            items: [
              for (final c in cases)
                DropdownMenuItem(
                  value: c.id,
                  child: Text('Case #${c.id} - ${c.title}'),
                ),
            ],
            onChanged: _uploading ? null : (v) => setState(() => _caseId = v!),
          ),
          const SizedBox(height: 20),
          const Text('Evidence Type',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final t in _EvidenceType.values)
                ChoiceChip(
                  label: Text(switch (t) {
                    _EvidenceType.documents => 'Documents',
                    _EvidenceType.images => 'Images',
                    _EvidenceType.videos => 'Videos',
                    _EvidenceType.other => 'Other',
                  }),
                  selected: _type == t,
                  onSelected: (_) => setState(() => _type = t),
                ),
            ],
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _files.isEmpty || _uploading ? null : _upload,
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
          for (final e in MockRepository.instance.recentEvidence().take(6))
            _RecentRow(e),
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

class _DropZone extends StatelessWidget {
  const _DropZone({required this.onTap});
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 16),
        decoration: BoxDecoration(
          color: AppColors.primarySoft.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.primary.withValues(alpha: 0.35)),
        ),
        child: const Column(
          children: [
            Icon(Icons.cloud_upload_outlined, size: 40, color: AppColors.primary),
            SizedBox(height: 12),
            Text('Drag and drop files here',
                style: TextStyle(fontWeight: FontWeight.w600)),
            SizedBox(height: 4),
            Text('or click to browse',
                style: TextStyle(color: AppColors.primary, fontSize: 13)),
            SizedBox(height: 8),
            Text('Supports: PDF, JPG, PNG, MP4, DOCX (Max 100MB)',
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
  const _RecentRow(this.file);
  final EvidenceFile file;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          _FileIcon(file.type),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(file.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w500)),
                Text('${file.sizeLabel} · ${file.type}',
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textSecondary)),
              ],
            ),
          ),
          Text(timeAgo(file.uploadedAt),
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
