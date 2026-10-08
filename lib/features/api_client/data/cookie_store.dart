import 'dart:io';

import 'package:flutter/foundation.dart';

/// A stored cookie with the effective domain/path it applies to.
@immutable
class StoredCookie {
  const StoredCookie({
    required this.name,
    required this.value,
    required this.domain,
    required this.path,
    required this.hostOnly,
    this.expires,
    this.secure = false,
    this.httpOnly = false,
  });

  final String name;
  final String value;
  final String domain;
  final String path;
  final bool hostOnly;
  final DateTime? expires;
  final bool secure;
  final bool httpOnly;

  bool isExpired(DateTime now) => expires != null && now.isAfter(expires!);

  bool matches(Uri uri, DateTime now) {
    if (isExpired(now)) return false;
    if (secure && uri.scheme != 'https') return false;
    final host = uri.host.toLowerCase();
    final domainOk = hostOnly
        ? host == domain
        : host == domain || host.endsWith('.$domain');
    if (!domainOk) return false;
    final reqPath = uri.path.isEmpty ? '/' : uri.path;
    return reqPath == path ||
        reqPath.startsWith(path.endsWith('/') ? path : '$path/') ||
        path == '/';
  }
}

/// Session-scoped cookie jar following the core rules of RFC 6265
/// (domain/path matching, expiry, secure). Cookies are kept in memory only so
/// session cookies never touch disk; see docs/security.md.
class CookieStore extends ChangeNotifier {
  CookieStore({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final List<StoredCookie> _cookies = [];

  List<StoredCookie> get all {
    final now = _clock();
    _cookies.removeWhere((c) => c.isExpired(now));
    return List.unmodifiable(_cookies);
  }

  List<StoredCookie> forUri(Uri uri) {
    final now = _clock();
    final matching = _cookies.where((c) => c.matches(uri, now)).toList()
      // Longer paths first, as browsers do.
      ..sort((a, b) => b.path.length.compareTo(a.path.length));
    return matching;
  }

  String? cookieHeaderFor(Uri uri) {
    final cookies = forUri(uri);
    if (cookies.isEmpty) return null;
    return cookies.map((c) => '${c.name}=${c.value}').join('; ');
  }

  /// Stores cookies from `Set-Cookie` header values received for [uri].
  List<Cookie> storeFromHeaders(Uri uri, Iterable<String> setCookieValues) {
    final parsed = <Cookie>[];
    for (final raw in setCookieValues) {
      try {
        parsed.add(Cookie.fromSetCookieValue(raw));
      } catch (_) {
        // Malformed cookies are ignored rather than failing the request.
      }
    }
    if (parsed.isEmpty) return parsed;
    final now = _clock();
    for (final c in parsed) {
      final host = uri.host.toLowerCase();
      var domain = (c.domain ?? '').toLowerCase();
      if (domain.startsWith('.')) domain = domain.substring(1);
      final hostOnly = domain.isEmpty;
      if (hostOnly) domain = host;
      // Reject cookies for unrelated domains.
      if (!(host == domain || host.endsWith('.$domain'))) continue;
      final path =
          (c.path == null || c.path!.isEmpty || !c.path!.startsWith('/'))
          ? _defaultPath(uri)
          : c.path!;
      final expires = c.maxAge != null
          ? now.add(Duration(seconds: c.maxAge!))
          : c.expires;
      _cookies.removeWhere(
        (e) => e.name == c.name && e.domain == domain && e.path == path,
      );
      final cookie = StoredCookie(
        name: c.name,
        value: c.value,
        domain: domain,
        path: path,
        hostOnly: hostOnly,
        expires: expires,
        secure: c.secure,
        httpOnly: c.httpOnly,
      );
      if (!cookie.isExpired(now)) _cookies.add(cookie);
    }
    notifyListeners();
    return parsed;
  }

  void remove(StoredCookie cookie) {
    _cookies.remove(cookie);
    notifyListeners();
  }

  void clearDomain(String domain) {
    _cookies.removeWhere((c) => c.domain == domain);
    notifyListeners();
  }

  void clear() {
    _cookies.clear();
    notifyListeners();
  }

  static String _defaultPath(Uri uri) {
    final path = uri.path;
    if (path.isEmpty || !path.startsWith('/')) return '/';
    final last = path.lastIndexOf('/');
    return last <= 0 ? '/' : path.substring(0, last);
  }
}
