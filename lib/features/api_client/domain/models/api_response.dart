import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'http_method.dart';

enum ResponseContentKind { json, xml, html, text, image, binary }

@immutable
class ResponseCookie {
  const ResponseCookie({
    required this.name,
    required this.value,
    this.domain,
    this.path,
    this.expires,
    this.httpOnly = false,
    this.secure = false,
    this.sameSite,
  });

  final String name;
  final String value;
  final String? domain;
  final String? path;
  final DateTime? expires;
  final bool httpOnly;
  final bool secure;
  final String? sameSite;

  factory ResponseCookie.fromIo(Cookie c) => ResponseCookie(
    name: c.name,
    value: c.value,
    domain: c.domain,
    path: c.path,
    expires:
        c.expires ??
        (c.maxAge != null
            ? DateTime.now().add(Duration(seconds: c.maxAge!))
            : null),
    httpOnly: c.httpOnly,
    secure: c.secure,
    sameSite: c.sameSite?.name,
  );
}

@immutable
class ApiResponse {
  ApiResponse({
    required this.statusCode,
    required this.statusMessage,
    required this.headers,
    required this.bodyBytes,
    required this.duration,
    required this.requestUrl,
    required this.method,
    this.cookies = const [],
    this.redirects = const [],
    DateTime? receivedAt,
  }) : receivedAt = receivedAt ?? DateTime.now();

  final int statusCode;
  final String statusMessage;

  /// Header name/value pairs in received order; names are lower-case.
  final List<MapEntry<String, String>> headers;
  final Uint8List bodyBytes;
  final Duration duration;
  final String requestUrl;
  final HttpMethod method;
  final List<ResponseCookie> cookies;
  final List<String> redirects;
  final DateTime receivedAt;

  int get bodySize => bodyBytes.length;

  int get headersSize =>
      headers.fold(0, (sum, h) => sum + h.key.length + h.value.length + 4);

  String? header(String name) {
    final lower = name.toLowerCase();
    for (final h in headers) {
      if (h.key == lower) return h.value;
    }
    return null;
  }

  String get contentType => header('content-type') ?? '';

  ResponseContentKind get contentKind {
    final ct = contentType.toLowerCase();
    if (ct.contains('json')) return ResponseContentKind.json;
    if (ct.contains('xml')) return ResponseContentKind.xml;
    if (ct.contains('html')) return ResponseContentKind.html;
    if (ct.startsWith('image/')) return ResponseContentKind.image;
    if (ct.startsWith('text/') ||
        ct.contains('javascript') ||
        ct.contains('x-www-form-urlencoded')) {
      return ResponseContentKind.text;
    }
    if (ct.isEmpty || ct.contains('octet-stream')) {
      return _sniff();
    }
    return ResponseContentKind.binary;
  }

  ResponseContentKind _sniff() {
    if (bodyBytes.isEmpty) return ResponseContentKind.text;
    final sample = bodyBytes.length > 512
        ? bodyBytes.sublist(0, 512)
        : bodyBytes;
    var control = 0;
    for (final b in sample) {
      if (b == 0) return ResponseContentKind.binary;
      if (b < 9 || (b > 13 && b < 32)) control++;
    }
    if (control > sample.length ~/ 10) return ResponseContentKind.binary;
    final trimmed = utf8.decode(sample, allowMalformed: true).trimLeft();
    final firstChar = trimmed.isEmpty ? null : trimmed[0];
    if (firstChar == '{' || firstChar == '[') return ResponseContentKind.json;
    if (firstChar == '<') return ResponseContentKind.xml;
    return ResponseContentKind.text;
  }

  bool get isTextual =>
      contentKind != ResponseContentKind.image &&
      contentKind != ResponseContentKind.binary;

  /// Decodes the body according to the declared charset (UTF-8 default).
  String get bodyText {
    final charset = RegExp(
      r'charset=([^;]+)',
      caseSensitive: false,
    ).firstMatch(contentType)?.group(1)?.trim().toLowerCase();
    if (charset == 'iso-8859-1' || charset == 'latin1') {
      return latin1.decode(bodyBytes, allowInvalid: true);
    }
    return utf8.decode(bodyBytes, allowMalformed: true);
  }

  String get suggestedFileName {
    final disposition = header('content-disposition');
    final match = disposition == null
        ? null
        : RegExp(
            r'''filename\*?=(?:UTF-8'')?["']?([^"';]+)''',
            caseSensitive: false,
          ).firstMatch(disposition);
    if (match != null) return Uri.decodeComponent(match.group(1)!);
    final segment = Uri.tryParse(requestUrl)?.pathSegments.lastOrNull ?? '';
    if (segment.contains('.')) return segment;
    final ext = switch (contentKind) {
      ResponseContentKind.json => 'json',
      ResponseContentKind.xml => 'xml',
      ResponseContentKind.html => 'html',
      ResponseContentKind.text => 'txt',
      ResponseContentKind.image => contentType.split('/').last.split(';').first,
      ResponseContentKind.binary => 'bin',
    };
    return 'response.$ext';
  }
}
