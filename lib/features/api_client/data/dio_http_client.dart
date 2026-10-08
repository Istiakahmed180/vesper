import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../core/errors/app_failure.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/network/cancel_handle.dart';
import '../../../core/network/network_error_mapper.dart';
import '../../../core/security/redactor.dart';
import '../../settings/domain/app_settings.dart';
import '../domain/models/api_response.dart';
import '../domain/models/prepared_request.dart';
import '../domain/repositories/http_client_port.dart';
import 'cookie_store.dart';

/// [HttpClientPort] backed by Dio + dart:io's HttpClient.
class DioHttpClient implements HttpClientPort {
  DioHttpClient({
    required this._logger,
    required this._cookies,
    this._errorMapper = const NetworkErrorMapper(),
  });

  final AppLogger _logger;
  final CookieStore _cookies;
  final NetworkErrorMapper _errorMapper;

  Dio? _dio;
  NetworkSettings? _dioSettings;

  Dio _clientFor(NetworkSettings settings) {
    if (_dio != null && _dioSettings == settings) return _dio!;
    _dio?.close(force: true);
    final dio = Dio(
      BaseOptions(
        responseType: ResponseType.bytes,
        validateStatus: (_) => true,
        receiveDataWhenStatusError: true,
        persistentConnection: true,
      ),
    );
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient()..autoUncompress = true;
        final proxy = settings.proxy;
        if (proxy.isUsable) {
          final bypass = proxy.bypassHosts;
          client.findProxy = (uri) => bypass.contains(uri.host.toLowerCase())
              ? 'DIRECT'
              : 'PROXY ${proxy.host.trim()}:${proxy.port}';
        }
        if (!settings.verifySsl) {
          client.badCertificateCallback = (_, _, _) => true;
        }
        return client;
      },
    );
    _dio = dio;
    _dioSettings = settings;
    return dio;
  }

  @override
  Future<ApiResponse> send(
    PreparedRequest request, {
    required NetworkSettings settings,
    CancelHandle? cancel,
  }) async {
    final dio = _clientFor(settings);
    final cancelToken = CancelToken();
    unawaited(
      cancel?.whenCancelled.then((_) => cancelToken.cancel('cancelled')),
    );

    final uri = Uri.parse(request.url);
    final headers = _mergeHeaders(request.headers);
    if (settings.sendCookies &&
        !headers.keys.any((k) => k.toLowerCase() == 'cookie')) {
      final cookieHeader = _cookies.cookieHeaderFor(uri);
      if (cookieHeader != null) headers['Cookie'] = cookieHeader;
    }

    final stopwatch = Stopwatch()..start();
    _logger.info('Request started', {
      'method': request.method.value,
      'url': Redactor.safeUrl(request.url),
    });

    try {
      final data = await _encodeBody(request.body, headers);
      final hasBody = data != null;
      final response = await dio.requestUri<List<int>>(
        uri,
        data: data,
        cancelToken: cancelToken,
        options: Options(
          method: request.method.value,
          headers: headers,
          followRedirects: request.followRedirects,
          maxRedirects: settings.maxRedirects,
          connectTimeout: request.timeout,
          receiveTimeout: request.timeout,
          sendTimeout: hasBody ? request.timeout : null,
          preserveHeaderCase: true,
          responseType: ResponseType.bytes,
          listFormat: ListFormat.multiCompatible,
        ),
      );
      stopwatch.stop();

      final responseHeaders = <MapEntry<String, String>>[
        for (final e in response.headers.map.entries)
          for (final v in e.value) MapEntry(e.key.toLowerCase(), v),
      ];
      final finalUri = response.realUri;
      final setCookies = response.headers.map['set-cookie'] ?? const [];
      final cookies = settings.sendCookies
          ? _cookies.storeFromHeaders(finalUri, setCookies)
          : _parseCookies(setCookies);

      final bytes = response.data == null
          ? Uint8List(0)
          : (response.data is Uint8List
                ? response.data! as Uint8List
                : Uint8List.fromList(response.data!));

      final result = ApiResponse(
        statusCode: response.statusCode ?? 0,
        statusMessage: response.statusMessage ?? '',
        headers: responseHeaders,
        bodyBytes: bytes,
        duration: stopwatch.elapsed,
        requestUrl: finalUri.toString(),
        method: request.method,
        cookies: [for (final c in cookies) ResponseCookie.fromIo(c)],
        redirects: [for (final r in response.redirects) r.location.toString()],
      );
      _logger.info('Response received', {
        'status': result.statusCode,
        'ms': stopwatch.elapsedMilliseconds,
        'bytes': result.bodySize,
      });
      return result;
    } catch (error, stack) {
      final failure = _errorMapper.map(error, timeout: request.timeout);
      if (failure.kind == NetworkFailureKind.cancelled) {
        _logger.info('Request cancelled', {
          'ms': stopwatch.elapsedMilliseconds,
        });
      } else {
        _logger.error(
          'Request failed',
          error: failure.debugDetail ?? failure.message,
          stackTrace: failure.kind == NetworkFailureKind.unknown ? stack : null,
          context: {
            'kind': failure.kind.name,
            'url': Redactor.safeUrl(request.url),
          },
        );
      }
      throw failure;
    }
  }

  /// Joins duplicate header names as HTTP allows (cookies with `; `).
  Map<String, Object> _mergeHeaders(List<MapEntry<String, String>> headers) {
    final result = <String, Object>{};
    for (final h in headers) {
      final existingKey = result.keys
          .where((k) => k.toLowerCase() == h.key.toLowerCase())
          .firstOrNull;
      if (existingKey == null) {
        result[h.key] = h.value;
      } else {
        final sep = h.key.toLowerCase() == 'cookie' ? '; ' : ', ';
        result[existingKey] = '${result[existingKey]}$sep${h.value}';
      }
    }
    return result;
  }

  Future<Object?> _encodeBody(
    PreparedBody body,
    Map<String, Object> headers,
  ) async {
    switch (body) {
      case NoBody():
        return null;
      case TextBody(:final text):
        return Uint8List.fromList(utf8.encode(text));
      case final UrlEncodedBody b:
        return Uint8List.fromList(utf8.encode(b.encode()));
      case MultipartBody(:final parts):
        final form = FormData();
        for (final part in parts) {
          switch (part) {
            case MultipartTextPart(:final name, :final value):
              form.fields.add(MapEntry(name, value));
            case MultipartFilePart(
              :final name,
              :final path,
              :final contentType,
            ):
              final file = File(path);
              if (path.isEmpty || !file.existsSync()) {
                throw NetworkFailure(
                  NetworkFailureKind.fileNotFound,
                  path.isEmpty
                      ? 'Select a file for form field "$name".'
                      : 'The file "${p.basename(path)}" for form field "$name" was not found. '
                            'It may have been moved or deleted.',
                );
              }
              form.files.add(
                MapEntry(
                  name,
                  await MultipartFile.fromFile(
                    path,
                    filename: p.basename(path),
                    contentType: contentType.isEmpty
                        ? null
                        : DioMediaType.parse(contentType),
                  ),
                ),
              );
          }
        }
        // Dio sets the multipart boundary itself.
        headers.removeWhere((k, _) => k.toLowerCase() == 'content-type');
        return form;
      case FileBody(:final path):
        final file = File(path);
        if (!file.existsSync()) {
          throw NetworkFailure(
            NetworkFailureKind.fileNotFound,
            'The file "${p.basename(path)}" was not found. It may have been moved or deleted.',
          );
        }
        headers['Content-Length'] = (await file.length()).toString();
        return file.openRead();
    }
  }

  List<Cookie> _parseCookies(List<String> values) {
    final out = <Cookie>[];
    for (final v in values) {
      try {
        out.add(Cookie.fromSetCookieValue(v));
      } catch (_) {}
    }
    return out;
  }

  @override
  void dispose() {
    _dio?.close(force: true);
    _dio = null;
  }
}
