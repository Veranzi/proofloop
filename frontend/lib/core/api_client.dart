import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'config.dart';

/// Supplies the `Authorization: Bearer ...` token for API calls.
typedef TokenProvider = Future<String> Function();

/// Thin HTTP client for the Cloud Run API.
///
/// Errors come back in the API's envelope
/// `{"error": {"code", "message", "field", "request_id"}}` and are thrown as
/// [ApiException] so screens can show `message` directly.
///
/// Tests replace [instance] with a client built on `http/testing.dart`'s
/// `MockClient`.
class ApiClient {
  ApiClient({
    http.Client? httpClient,
    TokenProvider? tokenProvider,
    String? baseUrl,
  })  : _http = httpClient ?? http.Client(),
        _baseUrl = baseUrl ?? AppConfig.apiBaseUrl,
        tokenProvider = tokenProvider ?? _noToken;

  static ApiClient instance = ApiClient();

  final http.Client _http;
  final String _baseUrl;

  /// Set by AuthService once someone signs in.
  TokenProvider tokenProvider;

  /// Set when Firebase App Check is active; returns null if no token.
  Future<String?> Function()? appCheckTokenProvider;

  static Future<String> _noToken() async =>
      throw const ApiException(401, 'unauthenticated', 'Sign in first.');

  Future<Map<String, String>> _headers({bool json = false}) async {
    final appCheck = await appCheckTokenProvider?.call();
    return {
      'Authorization': 'Bearer ${await tokenProvider()}',
      'X-Firebase-AppCheck': ?appCheck,
      if (json) 'Content-Type': 'application/json',
    };
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final uri = Uri.parse('$_baseUrl$path');
    return query == null || query.isEmpty
        ? uri
        : uri.replace(queryParameters: query);
  }

  Future<Map<String, dynamic>> get(String path,
      {Map<String, String>? query}) async {
    final res = await _send(
        () async => _http.get(_uri(path, query), headers: await _headers()));
    return _decode(res);
  }

  /// GET a file body (e.g. a CSV or JSON export) as text.
  Future<String> getText(String path, {Map<String, String>? query}) async {
    final res = await _send(
        () async => _http.get(_uri(path, query), headers: await _headers()));
    if (res.statusCode >= 300) _decode(res);
    return utf8.decode(res.bodyBytes);
  }

  Future<Map<String, dynamic>> post(String path,
          [Map<String, dynamic>? body]) =>
      _withBody('POST', path, body);

  Future<Map<String, dynamic>> patch(String path, Map<String, dynamic> body) =>
      _withBody('PATCH', path, body);

  Future<Map<String, dynamic>> put(String path, Map<String, dynamic> body) =>
      _withBody('PUT', path, body);

  Future<void> delete(String path) async {
    final res = await _send(
        () async => _http.delete(_uri(path), headers: await _headers()));
    _decode(res);
  }

  Future<Map<String, dynamic>> _withBody(
      String method, String path, Map<String, dynamic>? body) async {
    final res = await _send(() async {
      final request = http.Request(method, _uri(path))
        ..headers.addAll(await _headers(json: true))
        ..body = jsonEncode(body ?? const {});
      return http.Response.fromStream(await _http.send(request));
    });
    return _decode(res);
  }

  /// PUT raw bytes to a signed upload URL. No API auth header: the URL itself
  /// is the permission, and storage rejects extra or missing signed headers.
  Future<void> putSigned(
      String url, Uint8List bytes, Map<String, String> headers) async {
    final res = await _send(
        () => _http.put(Uri.parse(url), headers: headers, body: bytes));
    if (res.statusCode >= 300) {
      throw ApiException(
          res.statusCode, 'upload_failed', 'The file upload was refused.');
    }
  }

  Future<http.Response> _send(Future<http.Response> Function() call) async {
    try {
      return await call();
    } on http.ClientException {
      throw const ApiException(0, 'unreachable',
          "Can't reach the Pruflo server. Check your connection and try again.");
    }
  }

  Map<String, dynamic> _decode(http.Response res) {
    Object? body;
    try {
      body = res.body.isEmpty ? <String, dynamic>{} : jsonDecode(res.body);
    } on FormatException {
      body = null;
    }
    if (res.statusCode >= 300) {
      final error = (body is Map ? body['error'] : null) as Map? ?? const {};
      throw ApiException(
        res.statusCode,
        (error['code'] ?? 'error') as String,
        (error['message'] ?? 'Something went wrong (${res.statusCode}).')
            as String,
      );
    }
    return body is Map<String, dynamic> ? body : <String, dynamic>{};
  }
}

class ApiException implements Exception {
  const ApiException(this.status, this.code, this.message);
  final int status;
  final String code;
  final String message;

  @override
  String toString() => message;
}
