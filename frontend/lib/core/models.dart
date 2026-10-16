/// Case lifecycle. `wire` is the value the API sends and stores.
enum CaseStatus {
  awaitingEvidence('awaiting_evidence'),
  inReview('in_review'),
  completed('completed');

  const CaseStatus(this.wire);
  final String wire;
}

enum Priority { high, medium, low }

enum UserRole { investigator, reviewer, admin, viewer }

/// A reviewer's decision on a finding. Every finding starts as `pending`.
/// `wire` is the value the API sends and stores.
enum ReviewDecision {
  approve('approve'),
  reject('reject'),
  pending('pending');

  const ReviewDecision(this.wire);
  final String wire;
}

class CaseItem {
  const CaseItem({
    required this.id,
    required this.title,
    required this.category,
    required this.description,
    required this.status,
    required this.priority,
    required this.createdAt,
    required this.assignedTo,
  });

  final String id;
  final String title;
  final String category;
  final String description;
  final CaseStatus status;
  final Priority priority;
  final DateTime createdAt;
  final String assignedTo;
}

class EvidenceFile {
  const EvidenceFile({
    required this.name,
    required this.sizeLabel,
    required this.type,
    required this.uploadedAt,
    this.caseId,
  });

  final String name;
  final String sizeLabel;
  final String type; // PDF, DOCX, XLSX, CSV, JPG ...
  final DateTime uploadedAt;
  final String? caseId;
}

class ReportItem {
  const ReportItem({
    required this.title,
    required this.caseId,
    required this.createdAt,
  });

  final String title;
  final String caseId;
  final DateTime createdAt;
}

class AppUser {
  const AppUser({
    required this.name,
    required this.email,
    required this.role,
    this.active = true,
    this.phone = '',
    this.jobTitle = '',
  });

  final String name;
  final String email;
  final UserRole role;
  final bool active;
  final String phone;
  final String jobTitle;

  String get initials => name
      .split(' ')
      .where((p) => p.isNotEmpty)
      .take(2)
      .map((p) => p[0].toUpperCase())
      .join();

  String get firstName => name.split(' ').first;
}

class ActivityItem {
  const ActivityItem({
    required this.title,
    required this.caseId,
    required this.at,
    required this.kind,
  });

  final String title;
  final String caseId;
  final DateTime at;
  final ActivityKind kind;
}

enum ActivityKind { evidenceUploaded, reviewCompleted, reportGenerated }
