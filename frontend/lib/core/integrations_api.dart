import 'api_client.dart';
import 'api_endpoints.dart';
import 'integration_models.dart';

/// Integrations settings (endpoints 34–49), admin only.
/// Shapes are in Docs/Integrations_API_Contract.md.
class IntegrationsApi {
  IntegrationsApi([ApiClient? client]) : _client = client;

  final ApiClient? _client;
  ApiClient get _api => _client ?? ApiClient.instance;

  List<Map<String, dynamic>> _items(Map<String, dynamic> page) =>
      [for (final e in page['items'] as List) e as Map<String, dynamic>];

  // API keys -----------------------------------------------------------------

  /// 34
  Future<List<ApiKey>> apiKeys() async => _items(
          await _api.get(ApiEndpoints.apiKeys, query: {'limit': '200'}))
      .map(ApiKey.fromJson)
      .toList();

  /// 35: returns the key and its full secret, shown once.
  Future<(ApiKey, String)> createApiKey(
      {required String name, required Set<ApiScope> scopes}) async {
    final j = await _api.post(ApiEndpoints.apiKeys, {
      'name': name,
      'scopes': [for (final s in scopes) s.wire],
    });
    return (ApiKey.fromJson(j), j['secret'] as String);
  }

  /// 36: permanent.
  Future<void> revokeApiKey(String id) => _api.delete(ApiEndpoints.apiKey(id));

  // Webhooks -----------------------------------------------------------------

  /// 37
  Future<List<WebhookEndpoint>> webhooks() async =>
      _items(await _api.get(ApiEndpoints.webhooks))
          .map(WebhookEndpoint.fromJson)
          .toList();

  /// 38: returns the endpoint and its signing secret, shown once.
  Future<(WebhookEndpoint, String)> createWebhook({
    required String url,
    required String description,
    required Set<WebhookEvent> events,
  }) async {
    final j = await _api.post(ApiEndpoints.webhooks, {
      'url': url,
      'description': description,
      'events': [for (final e in events) e.wire],
    });
    return (WebhookEndpoint.fromJson(j), j['signing_secret'] as String);
  }

  /// 39
  Future<WebhookEndpoint> setWebhookActive(String id, bool active) async =>
      WebhookEndpoint.fromJson(
          await _api.patch(ApiEndpoints.webhook(id), {'active': active}));

  /// 40
  Future<void> deleteWebhook(String id) =>
      _api.delete(ApiEndpoints.webhook(id));

  /// 41: sends a `ping` straight away.
  Future<WebhookDelivery> sendTestEvent(String id) async =>
      WebhookDelivery.fromJson(await _api.post(ApiEndpoints.webhookTest(id)));

  // Document sources -----------------------------------------------------------

  /// 43: always lists every kind the API knows.
  Future<List<Connector>> connectors() async => [
        for (final j in _items(await _api.get(ApiEndpoints.connectors)))
          ?Connector.fromJson(j),
      ];

  /// 44
  Future<Map<String, dynamic>> connect(
          ConnectorKind kind, Map<String, dynamic> body) =>
      _api.put(ApiEndpoints.connector(kind.wire), body);

  /// 45
  Future<void> disconnect(ConnectorKind kind) =>
      _api.delete(ApiEndpoints.connector(kind.wire));

  // Rules ----------------------------------------------------------------------

  /// 46
  Future<List<ReconciliationRule>> rules() async =>
      _items(await _api.get(ApiEndpoints.rules))
          .map(ReconciliationRule.fromJson)
          .toList();

  /// 47: a parameter change returns the rule with its new version.
  Future<ReconciliationRule> updateRule(String id,
          {bool? enabled, Map<String, String>? params}) async =>
      ReconciliationRule.fromJson(await _api.patch(ApiEndpoints.rule(id), {
        'enabled': ?enabled,
        'params': ?params,
      }));

  // Providers ------------------------------------------------------------------

  /// 48
  Future<ProviderSettings> providers() async =>
      ProviderSettings.fromJson(await _api.get(ApiEndpoints.providers));

  /// 49
  Future<ProviderSettings> saveProviders(ProviderSettings settings) async =>
      ProviderSettings.fromJson(
          await _api.put(ApiEndpoints.providers, settings.toJson()));
}
