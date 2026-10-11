import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import '../../../core/security/redactor.dart';
import '../../../core/utils/id.dart';
import '../../api_client/domain/models/api_request.dart';
import '../../api_client/domain/models/http_method.dart';
import '../../api_client/domain/models/key_value.dart';
import '../../api_client/domain/models/request_auth.dart';
import '../../api_client/domain/services/url_utils.dart';

@immutable
class HistoryEntry {
  HistoryEntry({
    String? id,
    required this.request,
    this.requestId,
    this.statusCode,
    this.errorMessage,
    this.duration = Duration.zero,
    this.sizeBytes = 0,
    DateTime? executedAt,
  }) : id = id ?? newId(),
       executedAt = executedAt ?? DateTime.now();

  final String id;

  /// Saved request this execution came from, if any.
  final String? requestId;

  /// Sanitized snapshot of what was sent.
  final ApiRequest request;
  final int? statusCode;
  final String? errorMessage;
  final Duration duration;
  final int sizeBytes;
  final DateTime executedAt;

  HttpMethod get method => request.method;
  String get url => request.url;
  bool get failed => statusCode == null;
}

/// Removes literal secrets from request snapshots before they are written to
/// history. Values that are pure `{{variable}}` references are kept because
/// they are not secrets themselves and make re-running possible.
class HistorySanitizer {
  const HistorySanitizer();

  static final _reference = RegExp(r'^\s*(\{\{[^{}]+\}\}\s*)+$');

  static bool isReference(String value) =>
      value.isEmpty || _reference.hasMatch(value);

  String _clean(String value) => isReference(value) ? value : '';

  ApiRequest sanitize(ApiRequest request) {
    final headers = [
      for (final h in request.headers)
        Redactor.isSensitiveHeader(h.key) && !isReference(h.value)
            ? h.copyWith(value: '')
            : h,
    ];
    final params = [
      for (final p in request.params)
        Redactor.isSensitiveKey(p.key) && !isReference(p.value)
            ? p.copyWith(value: '')
            : p,
    ];
    final url = UrlUtils.urlWithParams(_stripUserInfo(request.url), params);
    final auth = switch (request.auth) {
      final BearerAuth a => BearerAuth(token: _clean(a.token)),
      final BasicAuth a => a.copyWith(password: _clean(a.password)),
      final ApiKeyAuth a => a.copyWith(value: _clean(a.value)),
      final OAuth2Auth a => a.copyWith(
        clientSecret: _clean(a.clientSecret),
        accessToken: _clean(a.accessToken),
        refreshToken: _clean(a.refreshToken),
      ),
      final NoAuth a => a,
      final InheritAuth a => a,
    };
    final urlEncoded = [
      for (final f in request.body.urlEncoded)
        Redactor.isSensitiveKey(f.key) && !isReference(f.value)
            ? f.copyWith(value: '')
            : f,
    ];
    return request.copyWith(
      url: url,
      headers: headers,
      params: params,
      auth: auth,
      body: request.body.copyWith(urlEncoded: urlEncoded),
    );
  }

  /// Whether sanitizing removed anything (shown as a notice in the UI).
  bool wasRedacted(ApiRequest original) {
    final s = sanitize(original);
    return s.auth != original.auth ||
        !const ListEquality<KeyValue>().equals(s.headers, original.headers) ||
        !const ListEquality<KeyValue>().equals(s.params, original.params) ||
        s.body != original.body ||
        s.url != original.url;
  }

  static String _stripUserInfo(String url) => url.replaceFirstMapped(
    RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@{}]*@'),
    (m) => m[1]!,
  );
}
