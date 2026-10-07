// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:soundwave/railway_api/api_config.dart';
import 'package:soundwave/railway_api/api_errors.dart';

class ApiClient {
  ApiClient({
    http.Client? client,
    this.baseUrl = ApiConfig.baseUrl,
    this.timeout = const Duration(seconds: 15),
    this.logger,
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;
  final Duration timeout;
  final void Function(String message)? logger;

  Uri buildUri(String path, [Map<String, String>? queryParameters]) {
    var cleanBase = baseUrl;
    while (cleanBase.endsWith('/')) {
      cleanBase = cleanBase.substring(0, cleanBase.length - 1);
    }

    var cleanPath = path;
    while (cleanPath.startsWith('/')) {
      cleanPath = cleanPath.substring(1);
    }

    if (cleanBase.endsWith('/api')) {
      if (cleanPath.startsWith('api/')) {
        cleanPath = cleanPath.substring(4);
      }
    } else {
      if (!cleanPath.startsWith('api/')) {
        cleanPath = 'api/$cleanPath';
      }
    }

    return Uri.parse('$cleanBase/$cleanPath').replace(
      queryParameters:
          queryParameters?.isEmpty == true ? null : queryParameters,
    );
  }

  Future<dynamic> get(
    String path, {
    Map<String, String> queryParameters = const {},
  }) async {
    final uri = buildUri(path, queryParameters);
    return _request(() => _client.get(uri), uri, 'GET');
  }

  Future<dynamic> post(String path, {Object? body}) async {
    final uri = buildUri(path);
    return _request(
      () => _client.post(
        uri,
        headers: const {'content-type': 'application/json'},
        body: body == null ? null : jsonEncode(body),
      ),
      uri,
      'POST',
    );
  }

  Future<dynamic> _request(
    Future<http.Response> Function() request,
    Uri uri,
    String method,
  ) async {
    Object? lastError;
    final endpoint = uri.path;

    print('[SEARCH]\nSEARCH_HTTP_START\nURL: $endpoint\nMETHOD: $method');

    for (var attempt = 1; attempt <= 2; attempt++) {
      final sw = Stopwatch()..start();
      try {
        logger?.call('Railway API request $endpoint (attempt $attempt)');
        final response = await request().timeout(timeout);
        sw.stop();

        print(
          '[SEARCH]\nSEARCH_HTTP_RESULT\nSTATUS: ${response.statusCode}\nDURATION_MS: ${sw.elapsedMilliseconds}',
        );

        if (response.statusCode >= 200 && response.statusCode < 300) {
          try {
            final decoded = jsonDecode(response.body);
            if (decoded is Map && decoded['success'] == false) {
              final errMsg = decoded['message']?.toString() ??
                  (decoded['error'] is Map
                      ? decoded['error']['message']?.toString()
                      : null) ??
                  'Upstream music service reported error.';
              final err = RailwayServerError(
                response.statusCode,
                errMsg,
                endpoint,
                _safeUrl(uri),
                _safeTruncate(response.body),
                _getRetryAfter(response.headers),
              );
              _logRequestFailed(
                method: method,
                endpoint: endpoint,
                status: response.statusCode,
                durationMs: sw.elapsedMilliseconds,
                reason: errMsg,
              );
              throw err;
            }
            return decoded;
          } on FormatException {
            throw const RailwayInvalidResponseError();
          }
        }

        final error = _statusError(
          response.statusCode,
          endpoint: endpoint,
          uri: uri,
          body: response.body,
          headers: response.headers,
        );

        _logRequestFailed(
          method: method,
          endpoint: endpoint,
          status: response.statusCode,
          durationMs: sw.elapsedMilliseconds,
          reason: _reasonFromStatus(response.statusCode),
        );

        if (!_isTransient(response.statusCode) || attempt == 2) {
          throw error;
        }
        lastError = error;
      } on TimeoutException {
        sw.stop();
        print(
          '[RAILWAY_API]\nREQUEST_FAILED\ntype=timeout\nendpoint=$endpoint\ntimeoutSeconds=${timeout.inSeconds}',
        );
        lastError = RailwayTimeoutError(
          'The request timed out.',
          endpoint,
          timeout.inSeconds,
        );
        if (attempt == 2) throw lastError;
      } on SocketException catch (error) {
        sw.stop();
        print(
          '[RAILWAY_API]\nREQUEST_FAILED\ntype=network\nendpoint=$endpoint\nerror=${error.message}',
        );
        lastError = RailwayNetworkError(
          error.message,
          endpoint,
          error,
        );
        if (attempt == 2) throw lastError;
      } on http.ClientException catch (error) {
        sw.stop();
        print(
          '[RAILWAY_API]\nREQUEST_FAILED\ntype=network\nendpoint=$endpoint\nerror=${error.message}',
        );
        lastError = RailwayNetworkError(
          error.message,
          endpoint,
          error,
        );
        if (attempt == 2) throw lastError;
      } on RailwayInvalidResponseError {
        rethrow;
      } on ApiError {
        if (attempt == 2 || lastError != null) rethrow;
      }
    }
    throw lastError ??
        RailwayNetworkError('Unknown network failure', endpoint);
  }

  ApiError _statusError(
    int statusCode, {
    required String endpoint,
    required Uri uri,
    required String body,
    required Map<String, String> headers,
  }) {
    final truncated = _safeTruncate(body);
    final retryAfter = _getRetryAfter(headers);
    final safeUrl = _safeUrl(uri);

    if (statusCode == 404) {
      return NotFoundError(endpoint, safeUrl, truncated);
    }
    if (statusCode == 429) {
      return RailwayRateLimitError(
        endpoint: endpoint,
        requestUrl: safeUrl,
        responseBody: truncated,
        retryAfter: retryAfter,
      );
    }
    if (statusCode >= 500) {
      return RailwayServerError(
        statusCode,
        _serverErrorMessage(statusCode),
        endpoint,
        safeUrl,
        truncated,
        retryAfter,
      );
    }
    return RailwayHttpError(
      statusCode,
      'The music service rejected the request ($statusCode).',
      endpoint,
      safeUrl,
      truncated,
      retryAfter,
    );
  }

  void _logRequestFailed({
    required String method,
    required String endpoint,
    required int status,
    required int durationMs,
    required String reason,
  }) {
    print(
      '[RAILWAY_API]\n'
      'REQUEST_FAILED\n'
      'method=$method\n'
      'endpoint=$endpoint\n'
      'status=$status\n'
      'durationMs=$durationMs\n'
      'reason=$reason',
    );
  }

  String _reasonFromStatus(int status) => switch (status) {
        500 => 'internal_server_error',
        502 => 'bad_gateway',
        503 => 'service_unavailable',
        504 => 'gateway_timeout',
        429 => 'rate_limited',
        404 => 'not_found',
        _ => 'http_$status',
      };

  String _serverErrorMessage(int status) => switch (status) {
        502 => 'Bad gateway from music service.',
        503 => 'Railway Music is temporarily unavailable.',
        504 => 'Gateway timeout from music service.',
        _ => 'The music service is unavailable (HTTP $status).',
      };

  bool _isTransient(int statusCode) =>
      statusCode >= 500 && statusCode <= 504;

  String _safeUrl(Uri uri) =>
      uri.replace(userInfo: '').toString();

  String _safeTruncate(String body, [int maxLength = 200]) {
    final clean = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    return clean.length <= maxLength
        ? clean
        : '${clean.substring(0, maxLength)}...';
  }

  String? _getRetryAfter(Map<String, String> headers) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'retry-after') {
        return entry.value;
      }
    }
    return null;
  }
}
