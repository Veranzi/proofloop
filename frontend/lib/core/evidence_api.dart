import 'dart:typed_data';

import 'api_client.dart';
import 'api_endpoints.dart';

/// A case as the upload screen needs it.
class CaseRef {
  const CaseRef({required this.id, required this.reference, required this.title});
  final String id; // opaque API ID, e.g. case_3f9c...
  final String reference; // shown to people, e.g. PL-001
  final String title;
}

/// An evidence file as returned by GET /v1/cases/{caseId}/evidence.
class EvidenceItem {
  const EvidenceItem({
    required this.id,
    required this.fileName,
    required this.sizeBytes,
    required this.status,
    required this.createdAt,
    this.errorClass,
  });

  factory EvidenceItem.fromJson(Map<String, dynamic> j) => EvidenceItem(
        id: j['id'] as String,
        fileName: j['file_name'] as String,
        sizeBytes: j['size_bytes'] as int,
        status: j['status'] as String,
        errorClass: j['error_class'] as String?,
        createdAt: DateTime.parse(j['created_at'] as String),
      );

  final String id;
  final String fileName;
  final int sizeBytes;
  final String status; // queued, processed, failed_terminal, ...
  final String? errorClass;
  final DateTime createdAt;
}

/// Content types the backend expects per extension
/// (backend/app/storage/file_types.py).
const evidenceContentTypes = {
  'pdf': 'application/pdf',
  'docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'csv': 'text/csv',
  'txt': 'text/plain',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'tif': 'image/tiff',
  'tiff': 'image/tiff',
};

/// Evidence calls against the real API (endpoints 3, 7, 8, 9).
class EvidenceApi {
  EvidenceApi([ApiClient? client]) : _api = client ?? ApiClient.instance;
  final ApiClient _api;

  Future<List<CaseRef>> cases() async {
    final page = await _api.get(ApiEndpoints.cases, query: {'limit': '200'});
    return [
      for (final c in page['items'] as List)
        CaseRef(
          id: c['id'] as String,
          reference: c['reference'] as String,
          title: c['title'] as String,
        ),
    ];
  }

  Future<List<EvidenceItem>> evidence(String caseId) async {
    final page =
        await _api.get(ApiEndpoints.evidence(caseId), query: {'limit': '6'});
    return [
      for (final e in page['items'] as List)
        EvidenceItem.fromJson(e as Map<String, dynamic>),
    ];
  }

  /// Ask for a signed URL (7), PUT the bytes, then complete (8) so the server
  /// verifies the file and queues processing. [onStep] reports 0..1.
  Future<EvidenceItem> upload({
    required String caseId,
    required String fileName,
    required Uint8List bytes,
    required List<String> evidenceTypes,
    void Function(double)? onStep,
  }) async {
    final ext = fileName.split('.').last.toLowerCase();
    final slot = await _api.post(ApiEndpoints.uploadUrl(caseId), {
      'file_name': fileName,
      'size_bytes': bytes.length,
      'content_type': evidenceContentTypes[ext] ?? 'application/octet-stream',
      'evidence_types': evidenceTypes,
    });
    onStep?.call(0.2);
    await _api.putSigned(
      slot['upload_url'] as String,
      bytes,
      Map<String, String>.from(slot['headers'] as Map),
    );
    onStep?.call(0.8);
    final done = await _api.post(ApiEndpoints.evidenceComplete(
        caseId, slot['evidence_id'] as String));
    onStep?.call(1);
    return EvidenceItem.fromJson(done);
  }
}
