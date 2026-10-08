import 'dart:convert';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/errors/app_failure.dart';
import '../models/api_request.dart';
import '../models/prepared_request.dart';
import '../models/request_auth.dart';
import '../models/request_body.dart';
import 'url_utils.dart';
import 'variable_resolver.dart';

class RequestDefaults {
  const RequestDefaults({
    this.timeoutMs = AppConstants.defaultTimeoutMs,
    this.followRedirects = true,
    this.userAgent = AppConstants.userAgent,
  });

  final int timeoutMs;
  final bool followRedirects;
  final String userAgent;
}

/// Turns an editable [ApiRequest] into a [PreparedRequest]: resolves
/// variables, applies authorization, builds the query string and body.
/// Pure Dart; shared by the HTTP executor and the cURL generator.
class RequestPreparer {
  const RequestPreparer();

  PreparedRequest prepare(
    ApiRequest request,
    VariableResolver resolver, {
    RequestDefaults defaults = const RequestDefaults(),
    bool validate = true,
  }) {
    final unresolved = <String>{};
    String r(String input) {
      final result = resolver.resolve(input);
      unresolved.addAll(result.unresolved);
      return result.value;
    }

    if (validate && request.url.trim().isEmpty) {
      throw const NetworkFailure(
        NetworkFailureKind.invalidUrl,
        'Enter a URL to send the request.',
      );
    }

    final parts = UrlParts.split(request.url);
    final baseResult = resolver.resolve(parts.base.trim());
    unresolved.addAll(baseResult.unresolved);
    final baseUrl = baseResult.value;
    if (validate && baseResult.unresolved.isNotEmpty) {
      final names = baseResult.unresolved.map((n) => '{{$n}}').join(', ');
      throw NetworkFailure(
        NetworkFailureKind.invalidUrl,
        'The URL contains an unresolved variable: $names. Select an environment that defines it.',
      );
    }
    final fragment = parts.fragment;
    // The URL text is the source of truth for the query: the editor keeps
    // the params table in sync with it and disabled params are not part of it.
    final query = <(String, String)>[
      for (final (k, v) in UrlUtils.parseQuery(parts.query ?? ''))
        if (k.isNotEmpty) (r(k), r(v)),
    ];

    final headers = <MapEntry<String, String>>[
      for (final h in request.headers)
        if (h.isActive) MapEntry(r(h.key).trim(), r(h.value)),
    ];

    _applyAuth(request.auth, headers, query, r);

    final body = request.method.allowsBody || request.body.type != BodyType.none
        ? _prepareBody(request.body, r)
        : const NoBody();

    final contentType = switch (body) {
      TextBody(:final contentType) => contentType,
      UrlEncodedBody() => 'application/x-www-form-urlencoded',
      FileBody(:final contentType) => contentType,
      _ => null,
    };
    if (contentType != null && !_has(headers, 'content-type')) {
      headers.add(MapEntry('Content-Type', contentType));
    }
    if (!_has(headers, 'user-agent') && defaults.userAgent.isNotEmpty) {
      headers.add(MapEntry('User-Agent', defaults.userAgent));
    }
    if (!_has(headers, 'accept')) {
      headers.add(const MapEntry('Accept', '*/*'));
    }

    final url = UrlUtils.buildRequestUrl(
      fragment == null ? baseUrl : '$baseUrl#${r(fragment)}',
      query,
    );
    if (validate) _validateUrl(url);

    return PreparedRequest(
      method: request.method,
      url: url,
      headers: headers,
      body: body,
      timeout: Duration(
        milliseconds: request.options.timeoutMs ?? defaults.timeoutMs,
      ),
      followRedirects:
          request.options.followRedirects ?? defaults.followRedirects,
      unresolvedVariables: unresolved,
    );
  }

  static bool _has(List<MapEntry<String, String>> headers, String name) =>
      headers.any((h) => h.key.toLowerCase() == name);

  void _validateUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      throw const NetworkFailure(NetworkFailureKind.invalidUrl, 'Invalid URL.');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw NetworkFailure(
        NetworkFailureKind.invalidUrl,
        'Unsupported protocol "${uri.scheme}". Only http and https are supported.',
      );
    }
  }

  void _applyAuth(
    RequestAuth auth,
    List<MapEntry<String, String>> headers,
    List<(String, String)> query,
    String Function(String) r,
  ) {
    void setHeader(String name, String value) {
      headers.removeWhere((h) => h.key.toLowerCase() == name.toLowerCase());
      headers.add(MapEntry(name, value));
    }

    switch (auth) {
      case NoAuth():
        break;
      case BearerAuth(:final token):
        final t = r(token).trim();
        if (t.isNotEmpty) setHeader('Authorization', 'Bearer $t');
      case BasicAuth(:final username, :final password):
        final u = r(username);
        if (u.isNotEmpty || password.isNotEmpty) {
          final encoded = base64.encode(utf8.encode('$u:${r(password)}'));
          setHeader('Authorization', 'Basic $encoded');
        }
      case ApiKeyAuth(:final key, :final value, :final location):
        final k = r(key).trim();
        if (k.isEmpty) break;
        if (location == ApiKeyLocation.header) {
          setHeader(k, r(value));
        } else {
          query.add((k, r(value)));
        }
      case OAuth2Auth(:final accessToken, :final headerPrefix):
        final t = r(accessToken).trim();
        if (t.isNotEmpty) {
          final prefix = headerPrefix.trim();
          setHeader('Authorization', prefix.isEmpty ? t : '$prefix $t');
        }
    }
  }

  PreparedBody _prepareBody(RequestBody body, String Function(String) r) {
    switch (body.type) {
      case BodyType.none:
        return const NoBody();
      case BodyType.json:
        return TextBody(r(body.text), 'application/json');
      case BodyType.raw:
        return TextBody(r(body.text), body.rawLanguage.contentType);
      case BodyType.urlEncoded:
        return UrlEncodedBody([
          for (final f in body.urlEncoded)
            if (f.isActive) (r(f.key), r(f.value)),
        ]);
      case BodyType.formData:
        return MultipartBody([
          for (final f in body.formData)
            if (f.isActive)
              if (f.kind == FormFieldKind.file)
                MultipartFilePart(
                  r(f.key),
                  f.filePath ?? '',
                  contentType: f.contentType,
                )
              else
                MultipartTextPart(r(f.key), r(f.value)),
        ]);
      case BodyType.binary:
        final path = body.binaryFilePath;
        if (path == null || path.isEmpty) return const NoBody();
        return FileBody(path, 'application/octet-stream');
    }
  }
}
