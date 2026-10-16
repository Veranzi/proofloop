/// Models for the Integrations settings (API keys, webhooks, connectors,
/// reconciliation rules and processing providers).
///
/// Field names follow the JSON contract in
/// Docs/Integrations_API_Contract.md, so swapping the mock data for real
/// API responses only needs `fromJson` constructors.
library;

/// Permission a system-to-system API key can be given.
enum ApiScope {
  casesRead('cases:read', 'Read cases'),
  casesWrite('cases:write', 'Create and update cases'),
  evidenceWrite('evidence:write', 'Upload evidence'),
  findingsRead('findings:read', 'Read findings and claims'),
  reportsRead('reports:read', 'Download reports and exports');

  const ApiScope(this.wire, this.label);

  /// Value sent to and received from the API.
  final String wire;
  final String label;
}

class ApiKey {
  const ApiKey({
    required this.id,
    required this.name,
    required this.prefix,
    required this.scopes,
    required this.createdAt,
    required this.createdBy,
    this.lastUsedAt,
    this.revoked = false,
  });

  final String id;
  final String name;

  /// First characters of the key, shown so admins can tell keys apart.
  /// The full secret is returned once, on creation, and never again.
  final String prefix;
  final Set<ApiScope> scopes;
  final DateTime createdAt;
  final String createdBy;
  final DateTime? lastUsedAt;
  final bool revoked;

  ApiKey copyWith({bool? revoked}) => ApiKey(
    id: id,
    name: name,
    prefix: prefix,
    scopes: scopes,
    createdAt: createdAt,
    createdBy: createdBy,
    lastUsedAt: lastUsedAt,
    revoked: revoked ?? this.revoked,
  );
}

/// Events PruFlo sends to webhook endpoints.
enum WebhookEvent {
  evidenceProcessed('evidence.processed', 'Evidence processed'),
  evidenceFailed('evidence.failed', 'Evidence processing failed'),
  caseReviewRequired('case.review_required', 'Case needs review'),
  findingDecided(
    'finding.decided',
    'Finding confirmed, corrected or dismissed',
  ),
  caseReviewed('case.reviewed', 'Case review completed'),
  reportReady('report.ready', 'Report or export ready');

  const WebhookEvent(this.wire, this.label);
  final String wire;
  final String label;
}

class WebhookDelivery {
  const WebhookDelivery({
    required this.event,
    required this.statusCode,
    required this.at,
    this.attempt = 1,
  });

  final WebhookEvent event;

  /// HTTP status returned by the receiver; 0 when it could not be reached.
  final int statusCode;
  final DateTime at;
  final int attempt;

  bool get succeeded => statusCode >= 200 && statusCode < 300;
}

class WebhookEndpoint {
  const WebhookEndpoint({
    required this.id,
    required this.url,
    required this.events,
    required this.createdAt,
    this.description = '',
    this.active = true,
    this.deliveries = const [],
  });

  final String id;
  final String url;
  final String description;
  final Set<WebhookEvent> events;
  final bool active;
  final DateTime createdAt;

  /// Most recent first.
  final List<WebhookDelivery> deliveries;

  WebhookEndpoint copyWith({bool? active, List<WebhookDelivery>? deliveries}) =>
      WebhookEndpoint(
        id: id,
        url: url,
        description: description,
        events: events,
        createdAt: createdAt,
        active: active ?? this.active,
        deliveries: deliveries ?? this.deliveries,
      );
}

/// Places documents can be pulled in from.
enum ConnectorKind {
  emailInbox(
    'email_inbox',
    'Email inbox',
    'Forward documents to a PruFlo address and they are added to a case.',
  ),
  googleDrive(
    'google_drive',
    'Google Drive',
    'Import files from a shared Drive folder.',
  ),
  sharePoint(
    'sharepoint',
    'SharePoint / OneDrive',
    'Import files from a SharePoint document library.',
  ),
  odoo(
    'odoo',
    'Odoo',
    'Pull purchase orders, delivery notes and vendor bills from Odoo.',
  ),
  sap(
    'sap',
    'SAP S/4HANA',
    'Pull purchase orders, goods receipts and invoices from SAP.',
  );

  const ConnectorKind(this.wire, this.label, this.description);
  final String wire;
  final String label;
  final String description;
}

enum ConnectorStatus { notConnected, connected, error, comingSoon }

class Connector {
  const Connector({
    required this.kind,
    required this.status,
    this.detail = '',
    this.connectedAt,
  });

  final ConnectorKind kind;
  final ConnectorStatus status;

  /// Inbox address, folder name, Odoo URL or error message.
  final String detail;
  final DateTime? connectedAt;
}

/// One configurable input of a rule, such as a tolerance.
class RuleParam {
  const RuleParam({
    required this.key,
    required this.label,
    required this.value,
    this.suffix = '',
  });

  final String key;
  final String label;

  /// Kept as a string; the API validates and stores it as a decimal.
  final String value;
  final String suffix;

  RuleParam withValue(String v) =>
      RuleParam(key: key, label: label, value: v, suffix: suffix);
}

/// A deterministic reconciliation rule. Code does the calculation; the
/// tenant only chooses which rules run and their parameters.
class ReconciliationRule {
  const ReconciliationRule({
    required this.id,
    required this.template,
    required this.name,
    required this.description,
    required this.version,
    required this.params,
    this.enabled = true,
  });

  final String id;

  /// Rule implementation in the backend, e.g. `quantity_shortfall`.
  final String template;
  final String name;
  final String description;

  /// Increases on every parameter change so findings stay reproducible.
  final int version;
  final List<RuleParam> params;
  final bool enabled;

  ReconciliationRule copyWith({bool? enabled, List<RuleParam>? params}) =>
      ReconciliationRule(
        id: id,
        template: template,
        name: name,
        description: description,
        version: params == null ? version : version + 1,
        params: params ?? this.params,
        enabled: enabled ?? this.enabled,
      );
}

enum OcrProvider {
  googleDocumentAi('google_document_ai', 'Google Document AI'),
  azureDocumentIntelligence(
    'azure_document_intelligence',
    'Azure AI Document Intelligence',
  ),
  awsTextract('aws_textract', 'AWS Textract'),
  selfHosted('self_hosted', 'Self-hosted (Tesseract)');

  const OcrProvider(this.wire, this.label);
  final String wire;
  final String label;
}

enum AiProvider {
  vertexGemini('vertex_gemini', 'Gemini on Vertex AI'),
  vertexClaude('vertex_claude', 'Claude on Vertex AI'),
  azureOpenAi('azure_openai', 'Azure OpenAI'),
  selfHosted('self_hosted', 'Self-hosted model');

  const AiProvider(this.wire, this.label);
  final String wire;
  final String label;
}

class ProcessingRegion {
  const ProcessingRegion(this.id, this.label);
  final String id;
  final String label;
}

class ProviderSettings {
  const ProviderSettings({
    required this.ocr,
    required this.ai,
    required this.model,
    required this.region,
  });

  final OcrProvider ocr;
  final AiProvider ai;

  /// Model ID from configuration, never hard-coded in the worker.
  final String model;
  final String region;
}
