import 'config.dart';

/// REST endpoints of the Cloud Run API (FastAPI). Numbers match
/// Docs/API_Contract.md and Docs/Integrations_API_Contract.md.
///
/// Every call except the signed-URL upload sends:
/// `Authorization: Bearer {Firebase ID token}` and
/// `X-Firebase-AppCheck: {App Check token}`.
class ApiEndpoints {
  ApiEndpoints._();

  /// Set at build time: --dart-define=API_BASE_URL=https://...run.app
  static const baseUrl = AppConfig.apiBaseUrl;

  // Profile and session
  static const me = '/v1/me'; // 1 GET, 21 PATCH
  static const devices = '/v1/devices'; // 2 POST
  static String device(String id) => '/v1/devices/$id'; // 22 DELETE
  static const myActivity = '/v1/me/activity'; // 23 GET

  // Cases
  static const cases = '/v1/cases'; // 3 GET, 4 POST
  static String caseById(String id) => '/v1/cases/$id'; // 5 GET, 6 PATCH

  // Evidence
  static String uploadUrl(String caseId) =>
      '/v1/cases/$caseId/evidence/upload-url'; // 7 POST
  static String evidenceComplete(String caseId, String evidenceId) =>
      '/v1/cases/$caseId/evidence/$evidenceId/complete'; // 8 POST
  static String evidence(String caseId) =>
      '/v1/cases/$caseId/evidence'; // 9 GET
  static String evidenceRetry(String caseId, String evidenceId) =>
      '/v1/cases/$caseId/evidence/$evidenceId/retry'; // 10 POST
  static String evidenceViewUrl(String caseId, String evidenceId) =>
      '/v1/cases/$caseId/evidence/$evidenceId/view-url'; // 11 GET
  static String evidenceAnchors(String caseId, String evidenceId) =>
      '/v1/cases/$caseId/evidence/$evidenceId/anchors'; // 12 GET

  // Claims, findings, review
  static String claims(String caseId) => '/v1/cases/$caseId/claims'; // 13
  static String findings(String caseId) => '/v1/cases/$caseId/findings'; // 14
  static String decision(String caseId, String findingId) =>
      '/v1/cases/$caseId/findings/$findingId/decision'; // 15 POST
  static String timeline(String caseId) => '/v1/cases/$caseId/timeline'; // 16

  // Reports
  static String reports(String caseId) =>
      '/v1/cases/$caseId/reports'; // 17 POST, 18 GET
  static String reportDownload(String caseId, String reportId) =>
      '/v1/cases/$caseId/reports/$reportId/download-url'; // 19 GET

  // Optional case Q&A
  static String qa(String caseId) => '/v1/cases/$caseId/qa'; // 20 POST

  // Admin
  static const adminUsers = '/v1/admin/users'; // 24 GET, 25 POST
  static String adminUser(String id) => '/v1/admin/users/$id'; // 26, 27
  static const adminCustomers = '/v1/admin/customers'; // 28, 29
  static String adminCustomer(String id) => '/v1/admin/customers/$id'; // 30
  static String adminCaseMembers(String caseId) =>
      '/v1/admin/cases/$caseId/members'; // 31 GET, 32 PUT
  static const adminAudit = '/v1/admin/audit'; // 33 GET

  // Integrations (admin). Contract: Docs/Integrations_API_Contract.md
  static const apiKeys = '/v1/admin/api-keys'; // 34 GET, 35 POST
  static String apiKey(String id) => '/v1/admin/api-keys/$id'; // 36 DELETE
  static const webhooks = '/v1/admin/webhooks'; // 37 GET, 38 POST
  static String webhook(String id) =>
      '/v1/admin/webhooks/$id'; // 39 PATCH, 40 DELETE
  static String webhookTest(String id) =>
      '/v1/admin/webhooks/$id/test'; // 41 POST
  static String webhookDeliveries(String id) =>
      '/v1/admin/webhooks/$id/deliveries'; // 42 GET
  static const connectors = '/v1/admin/connectors'; // 43 GET
  static String connector(String kind) =>
      '/v1/admin/connectors/$kind'; // 44 PUT, 45 DELETE
  static const rules = '/v1/admin/rules'; // 46 GET
  static String rule(String id) => '/v1/admin/rules/$id'; // 47 PATCH
  static const providers = '/v1/admin/providers'; // 48 GET, 49 PUT

  // Machine-readable export of findings: ?format=json|csv
  static String caseExport(String caseId) =>
      '/v1/cases/$caseId/export'; // 50 GET

  // Notifications, profile photo and customer picker
  static const notifications = '/v1/me/notifications'; // 51 GET
  static String notificationRead(String id) =>
      '/v1/me/notifications/$id/read'; // 52 POST
  static const notificationsReadAll =
      '/v1/me/notifications/read-all'; // 53 POST
  static const avatarUploadUrl = '/v1/me/avatar/upload-url'; // 54 POST
  static const avatarComplete = '/v1/me/avatar/complete'; // 55 POST
  static const avatar = '/v1/me/avatar'; // 56 DELETE
  static const customers = '/v1/customers'; // 57 GET
}
