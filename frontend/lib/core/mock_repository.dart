import 'models.dart';

/// In-memory data used until the Cloud Run API is available.
///
/// Each method notes the endpoint (see [ApiEndpoints]) it will call once the
/// backend is ready, so swapping to real HTTP calls is a one-file change.
class MockRepository {
  MockRepository._();
  static final instance = MockRepository._();

  final DateTime _now = DateTime.now();

  late final List<CaseItem> _cases = [
    CaseItem(
      id: 'PL-001',
      title: 'Fraud Investigation',
      category: 'Fraud',
      description:
          'Investigate potential fraudulent activity in the financial records.',
      status: CaseStatus.inReview,
      priority: Priority.high,
      createdAt: _now.subtract(const Duration(hours: 2)),
      assignedTo: 'Alex Carter',
    ),
    CaseItem(
      id: 'PL-002',
      title: 'Contract Verification',
      category: 'Legal',
      description: 'Verify signatures and terms on the supplier contract.',
      status: CaseStatus.awaitingEvidence,
      priority: Priority.medium,
      createdAt: _now.subtract(const Duration(hours: 5)),
      assignedTo: 'Sarah Johnson',
    ),
    CaseItem(
      id: 'PL-003',
      title: 'Background Check',
      category: 'HR',
      description: 'Confirm employment history and references.',
      status: CaseStatus.completed,
      priority: Priority.low,
      createdAt: _now.subtract(const Duration(days: 1)),
      assignedTo: 'Alex Carter',
    ),
    CaseItem(
      id: 'PL-004',
      title: 'Identity Verification',
      category: 'KYC',
      description: 'Match submitted ID documents against the applicant.',
      status: CaseStatus.inReview,
      priority: Priority.medium,
      createdAt: _now.subtract(const Duration(days: 1)),
      assignedTo: 'Emily Davis',
    ),
    CaseItem(
      id: 'PL-005',
      title: 'Financial Audit',
      category: 'Finance',
      description: 'Reconcile quarterly statements with bank records.',
      status: CaseStatus.completed,
      priority: Priority.low,
      createdAt: _now.subtract(const Duration(days: 2)),
      assignedTo: 'Michael Brown',
    ),
    CaseItem(
      id: 'PL-006',
      title: 'Vendor Assessment',
      category: 'Procurement',
      description: 'Assess vendor compliance documents.',
      status: CaseStatus.awaitingEvidence,
      priority: Priority.medium,
      createdAt: _now.subtract(const Duration(days: 3)),
      assignedTo: 'David Wilson',
    ),
  ];

  late final List<EvidenceFile> _evidence = [
    EvidenceFile(
        name: 'document.pdf',
        sizeLabel: '2.4 MB',
        type: 'PDF',
        uploadedAt: _now.subtract(const Duration(hours: 2)),
        caseId: 'PL-001'),
    EvidenceFile(
        name: 'photo.jpg',
        sizeLabel: '1.8 MB',
        type: 'JPG',
        uploadedAt: _now.subtract(const Duration(hours: 3)),
        caseId: 'PL-001'),
    EvidenceFile(
        name: 'stock_count.csv',
        sizeLabel: '96 KB',
        type: 'CSV',
        uploadedAt: _now.subtract(const Duration(hours: 5)),
        caseId: 'PL-002'),
    EvidenceFile(
        name: 'spreadsheet.xlsx',
        sizeLabel: '856 KB',
        type: 'XLSX',
        uploadedAt: _now.subtract(const Duration(days: 1)),
        caseId: 'PL-004'),
  ];

  late final List<ReportItem> _reports = [
    ReportItem(
        title: 'Fraud Investigation Report',
        caseId: 'PL-001',
        createdAt: _now.subtract(const Duration(hours: 2))),
    ReportItem(
        title: 'Contract Verification Report',
        caseId: 'PL-002',
        createdAt: _now.subtract(const Duration(days: 1))),
    ReportItem(
        title: 'Background Check Report',
        caseId: 'PL-003',
        createdAt: _now.subtract(const Duration(days: 2))),
  ];

  late final List<ActivityItem> _activity = [
    ActivityItem(
        title: 'Evidence uploaded',
        caseId: 'PL-001',
        at: _now.subtract(const Duration(hours: 2)),
        kind: ActivityKind.evidenceUploaded),
    ActivityItem(
        title: 'Review completed',
        caseId: 'PL-003',
        at: _now.subtract(const Duration(hours: 5)),
        kind: ActivityKind.reviewCompleted),
    ActivityItem(
        title: 'Report generated',
        caseId: 'PL-002',
        at: _now.subtract(const Duration(days: 1)),
        kind: ActivityKind.reportGenerated),
  ];

  final List<AppUser> _users = const [
    AppUser(
        name: 'Alex Carter',
        email: 'alex@company.com',
        role: UserRole.investigator,
        phone: '+1 (555) 123-4567',
        jobTitle: 'Investigator'),
    AppUser(
        name: 'Sarah Johnson',
        email: 'sarah@company.com',
        role: UserRole.reviewer),
    AppUser(
        name: 'Michael Brown',
        email: 'michael@company.com',
        role: UserRole.admin),
    AppUser(
        name: 'Emily Davis', email: 'emily@company.com', role: UserRole.viewer),
    AppUser(
        name: 'David Wilson',
        email: 'david@company.com',
        role: UserRole.reviewer,
        active: false),
  ];

  /// GET /v1/cases (endpoint 3)
  List<CaseItem> cases() => List.unmodifiable(_cases);

  /// POST /v1/cases (endpoint 4). The server assigns the id.
  CaseItem addCase({
    required String title,
    required String category,
    required String description,
    required Priority priority,
    required String assignedTo,
  }) {
    final next = _cases.length + 1;
    final item = CaseItem(
      id: 'PL-${next.toString().padLeft(3, '0')}',
      title: title,
      category: category,
      description: description,
      status: CaseStatus.awaitingEvidence,
      priority: priority,
      createdAt: DateTime.now(),
      assignedTo: assignedTo,
    );
    _cases.insert(0, item);
    return item;
  }

  /// GET /v1/cases/{caseId} (endpoint 5)
  CaseItem? caseById(String id) {
    for (final c in _cases) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// GET /v1/cases/{caseId}/evidence (endpoint 9), across the user's cases
  List<EvidenceFile> recentEvidence() => List.unmodifiable(_evidence);

  /// Records a finished upload. With the real backend the file goes to a
  /// signed URL (endpoints 7 and 8) and the worker picks it up via Pub/Sub.
  void addEvidence(EvidenceFile file) => _evidence.insert(0, file);

  /// GET /v1/cases/{caseId}/reports (endpoint 18), across the user's cases
  List<ReportItem> reports() => List.unmodifiable(_reports);

  /// POST /v1/cases/{caseId}/reports (endpoint 17)
  void addReport(ReportItem report) => _reports.insert(0, report);

  /// GET /v1/me/activity (endpoint 23)
  List<ActivityItem> activity() => List.unmodifiable(_activity);

  /// GET /v1/admin/users (endpoint 24)
  List<AppUser> users() => List.unmodifiable(_users);
}
