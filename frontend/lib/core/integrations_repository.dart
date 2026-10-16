import 'dart:math';

import 'integration_models.dart';

/// In-memory Integrations data used until the Cloud Run API is available.
///
/// As in [MockRepository], each method names the endpoint (see
/// [ApiEndpoints]) it will call. The request and response shapes are in
/// Docs/Integrations_API_Contract.md.
class IntegrationsRepository {
  IntegrationsRepository._();
  static final instance = IntegrationsRepository._();

  final DateTime _now = DateTime.now();
  final _random = Random.secure();

  static const regions = [
    ProcessingRegion('asia-southeast1', 'Singapore (asia-southeast1)'),
    ProcessingRegion('asia-southeast2', 'Jakarta (asia-southeast2)'),
  ];

  late final List<ApiKey> _keys = [
    ApiKey(
      id: 'key_01',
      name: 'Odoo sync job',
      prefix: 'pf_live_7Hq2',
      scopes: {ApiScope.casesWrite, ApiScope.evidenceWrite},
      createdAt: _now.subtract(const Duration(days: 12)),
      createdBy: 'Michael Brown',
      lastUsedAt: _now.subtract(const Duration(hours: 3)),
    ),
    ApiKey(
      id: 'key_02',
      name: 'Finance dashboard (read only)',
      prefix: 'pf_live_Kd91',
      scopes: {ApiScope.casesRead, ApiScope.findingsRead},
      createdAt: _now.subtract(const Duration(days: 30)),
      createdBy: 'Alex Carter',
      revoked: true,
    ),
  ];

  late final List<WebhookEndpoint> _webhooks = [
    WebhookEndpoint(
      id: 'wh_01',
      url: 'https://erp.example.com/hooks/pruflo',
      description: 'ERP exception queue',
      events: {WebhookEvent.caseInReview, WebhookEvent.findingDecided},
      createdAt: _now.subtract(const Duration(days: 9)),
      deliveries: [
        WebhookDelivery(
          event: WebhookEvent.findingDecided,
          statusCode: 200,
          at: _now.subtract(const Duration(hours: 1)),
        ),
        WebhookDelivery(
          event: WebhookEvent.caseInReview,
          statusCode: 503,
          attempt: 2,
          at: _now.subtract(const Duration(hours: 4)),
        ),
      ],
    ),
  ];

  late final List<Connector> _connectors = [
    Connector(
      kind: ConnectorKind.emailInbox,
      status: ConnectorStatus.connected,
      detail: 'evidence+acme@in.pruflo.app',
      connectedAt: _now.subtract(const Duration(days: 20)),
    ),
    const Connector(
      kind: ConnectorKind.googleDrive,
      status: ConnectorStatus.notConnected,
    ),
    const Connector(
      kind: ConnectorKind.sharePoint,
      status: ConnectorStatus.notConnected,
    ),
    const Connector(
      kind: ConnectorKind.odoo,
      status: ConnectorStatus.notConnected,
    ),
    const Connector(
      kind: ConnectorKind.sap,
      status: ConnectorStatus.comingSoon,
    ),
  ];

  final List<ReconciliationRule> _rules = [
    const ReconciliationRule(
      id: 'rule_qty',
      template: 'quantity_shortfall',
      name: 'Quantity shortfall',
      description: 'Ordered quantity vs delivered quantity, same unit.',
      version: 3,
      params: [
        RuleParam(
          key: 'tolerance_units',
          label: 'Allowed difference',
          value: '0',
          suffix: 'units',
        ),
      ],
    ),
    const ReconciliationRule(
      id: 'rule_amount',
      template: 'amount_mismatch',
      name: 'Invoice vs order amount',
      description: 'Invoice total vs purchase order total, same currency.',
      version: 1,
      params: [
        RuleParam(
          key: 'tolerance_percent',
          label: 'Allowed difference',
          value: '0.5',
          suffix: '%',
        ),
      ],
    ),
    const ReconciliationRule(
      id: 'rule_date',
      template: 'delivery_date_window',
      name: 'Late delivery',
      description: 'Delivery date vs promised date.',
      version: 1,
      enabled: false,
      params: [
        RuleParam(
          key: 'grace_days',
          label: 'Grace period',
          value: '2',
          suffix: 'days',
        ),
      ],
    ),
    const ReconciliationRule(
      id: 'rule_missing',
      template: 'missing_document',
      name: 'Missing supporting document',
      description:
          'Flags an order with no matching delivery note or invoice in the '
          'documents reviewed. Absence of evidence, not proof of non-delivery.',
      version: 1,
      params: [],
    ),
  ];

  ProviderSettings _providers = const ProviderSettings(
    ocr: OcrProvider.googleDocumentAi,
    ai: AiProvider.vertexGemini,
    model: 'gemini-2.5-flash',
    region: 'asia-southeast1',
  );

  // API keys

  /// GET /v1/admin/api-keys (endpoint 34)
  List<ApiKey> apiKeys() => List.unmodifiable(_keys);

  /// POST /v1/admin/api-keys (endpoint 35). Returns the key and its full
  /// secret; the secret is shown once and is not stored by the client.
  (ApiKey, String) createApiKey({
    required String name,
    required Set<ApiScope> scopes,
    required String createdBy,
  }) {
    final secret = 'pf_live_${_token(32)}';
    final key = ApiKey(
      id: 'key_${_token(6)}',
      name: name,
      prefix: secret.substring(0, 12),
      scopes: scopes,
      createdAt: DateTime.now(),
      createdBy: createdBy,
    );
    _keys.insert(0, key);
    return (key, secret);
  }

  /// DELETE /v1/admin/api-keys/{keyId} (endpoint 36). Revoked keys stay
  /// listed for the audit trail.
  void revokeApiKey(String id) =>
      _replace(_keys, (k) => k.id == id, (k) => k.copyWith(revoked: true));

  // Webhooks

  /// GET /v1/admin/webhooks (endpoint 37)
  List<WebhookEndpoint> webhooks() => List.unmodifiable(_webhooks);

  /// POST /v1/admin/webhooks (endpoint 38). Returns the endpoint and its
  /// signing secret, shown once.
  (WebhookEndpoint, String) createWebhook({
    required String url,
    required String description,
    required Set<WebhookEvent> events,
  }) {
    final hook = WebhookEndpoint(
      id: 'wh_${_token(6)}',
      url: url,
      description: description,
      events: events,
      createdAt: DateTime.now(),
    );
    _webhooks.insert(0, hook);
    return (hook, 'whsec_${_token(32)}');
  }

  /// PATCH /v1/admin/webhooks/{webhookId} (endpoint 39)
  void setWebhookActive(String id, bool active) =>
      _replace(_webhooks, (w) => w.id == id, (w) => w.copyWith(active: active));

  /// DELETE /v1/admin/webhooks/{webhookId} (endpoint 40)
  void deleteWebhook(String id) => _webhooks.removeWhere((w) => w.id == id);

  /// POST /v1/admin/webhooks/{webhookId}/test (endpoint 41). Sends a
  /// `ping` event; the mock records a successful delivery.
  WebhookDelivery sendTestEvent(String id) {
    final delivery = WebhookDelivery(
      event: WebhookEvent.evidenceProcessed,
      statusCode: 200,
      at: DateTime.now(),
    );
    _replace(
      _webhooks,
      (w) => w.id == id,
      (w) => w.copyWith(deliveries: [delivery, ...w.deliveries]),
    );
    return delivery;
  }

  // Connectors

  /// GET /v1/admin/connectors (endpoint 43)
  List<Connector> connectors() => List.unmodifiable(_connectors);

  /// PUT /v1/admin/connectors/{kind} (endpoint 44). Drive and SharePoint
  /// return an `authorization_url` for the OAuth consent screen; the mock
  /// skips that step.
  Connector connect(ConnectorKind kind, {String detail = ''}) {
    final connector = Connector(
      kind: kind,
      status: ConnectorStatus.connected,
      detail: kind == ConnectorKind.emailInbox
          ? 'evidence+${_token(4).toLowerCase()}@in.pruflo.app'
          : detail,
      connectedAt: DateTime.now(),
    );
    _replace(_connectors, (c) => c.kind == kind, (_) => connector);
    return connector;
  }

  /// DELETE /v1/admin/connectors/{kind} (endpoint 45)
  void disconnect(ConnectorKind kind) => _replace(
    _connectors,
    (c) => c.kind == kind,
    (_) => Connector(kind: kind, status: ConnectorStatus.notConnected),
  );

  // Rules

  /// GET /v1/admin/rules (endpoint 46)
  List<ReconciliationRule> rules() => List.unmodifiable(_rules);

  /// PATCH /v1/admin/rules/{ruleId} (endpoint 47). A parameter change
  /// creates a new rule version; findings keep the version that made them.
  void updateRule(ReconciliationRule rule) =>
      _replace(_rules, (r) => r.id == rule.id, (_) => rule);

  // Providers

  /// GET /v1/admin/providers (endpoint 48)
  ProviderSettings providers() => _providers;

  /// PUT /v1/admin/providers (endpoint 49). Applies to evidence processed
  /// after the change.
  void saveProviders(ProviderSettings settings) => _providers = settings;

  void _replace<T>(List<T> list, bool Function(T) test, T Function(T) update) {
    final i = list.indexWhere(test);
    if (i >= 0) list[i] = update(list[i]);
  }

  String _token(int length) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(
      length,
      (_) => chars[_random.nextInt(chars.length)],
    ).join();
  }
}
