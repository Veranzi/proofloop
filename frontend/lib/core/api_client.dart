import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'api_endpoints.dart';
import 'auth_service.dart';

/// Thin HTTP client for the Cloud Run API.
///
/// Errors come back in the API's envelope
/// `{"error": {"code", "message", "field", "request_id"}}` and are thrown as
/// [ApiException] so screens can show `message` directly.
class ApiClient {
  ApiClient({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  static final instance = ApiClient();

  final http.Client _http;

  Future<Map<String, String>> _headers({bool json = false}) async => {
        'Authorization': 'Bearer ${await AuthService.instance.idToken()}',
        if (json) 'Content-Type': 'application/json',
      };

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('${ApiEndpoints.baseUrl}$path').replace(queryParameters: query);

  Future<Map<String, dynamic>> get(String path,
      {Map<String, String>? query}) async {
    final res = await _send(() async =>
        _http.get(_uri(path, query), headers: await _headers()));
    return _decode(res);
  }

  Future<Map<String, dynamic>> post(String path,
      [Map<String, dynamic>? body]) async {
    final res = await _send(() async => _http.post(
          _uri(path),
          headers: await _headers(json: true),
          body: jsonEncode(body ?? const {}),
        ));
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
    final body = res.body.isEmpty ? <String, dynamic>{} : jsonDecode(res.body);
    if (res.statusCode >= 300) {
      final error = (body is Map ? body['error'] : null) as Map? ?? const {};
      throw ApiException(
        res.statusCode,
        (error['code'] ?? 'error') as String,
        (error['message'] ?? 'Something went wrong.') as String,
      );
    }
    return body as Map<String, dynamic>;
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
