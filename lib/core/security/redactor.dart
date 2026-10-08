/// Helpers that keep secrets out of logs, history and exports.
class Redactor {
  const Redactor._();

  static const mask = '••••••••';

  static const _sensitiveHeaderNames = {
    'authorization',
    'proxy-authorization',
    'cookie',
    'set-cookie',
    'x-api-key',
    'api-key',
    'x-auth-token',
    'x-access-token',
    'x-csrf-token',
    'x-amz-security-token',
  };

  static const _sensitiveKeyFragments = [
    'token',
    'secret',
    'password',
    'passwd',
    'apikey',
    'api_key',
    'api-key',
    'auth',
    'session',
    'signature',
    'credential',
    'private',
  ];

  static bool isSensitiveHeader(String name) {
    final lower = name.trim().toLowerCase();
    return _sensitiveHeaderNames.contains(lower) || isSensitiveKey(lower);
  }

  static bool isSensitiveKey(String key) {
    final lower = key.toLowerCase();
    return _sensitiveKeyFragments.any(lower.contains);
  }

  /// Masks a secret for display, keeping a short prefix for recognisability
  /// only when the value is long enough that the prefix leaks little.
  static String maskValue(String value, {bool keepPrefix = false}) {
    if (value.isEmpty) return '';
    if (keepPrefix && value.length >= 16) {
      return '${value.substring(0, 4)}$mask';
    }
    return mask;
  }

  /// Removes query values, fragments and userinfo from a URL so it can be logged.
  static String safeUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      final cut = url.indexOf(RegExp('[?#]'));
      return cut == -1 ? url : '${url.substring(0, cut)}?…';
    }
    final port = uri.hasPort ? ':${uri.port}' : '';
    final base = '${uri.scheme}://${uri.host}$port${uri.path}';
    return uri.hasQuery ? '$base?…' : base;
  }

  static final _patterns = <RegExp>[
    RegExp(r'(bearer\s+)[A-Za-z0-9\-._~+/]+=*', caseSensitive: false),
    RegExp(r'(basic\s+)[A-Za-z0-9+/]+=*', caseSensitive: false),
    RegExp(
      r'''((?:access_token|refresh_token|id_token|client_secret|password|api_key|apikey|token)["']?\s*[:=]\s*["']?)[^"'&\s,}]+''',
      caseSensitive: false,
    ),
    RegExp(r'\b(gh[pousr]_)[A-Za-z0-9]{20,}'),
    RegExp(r'\b(ya29\.)[A-Za-z0-9\-_]+'),
  ];

  /// Defensive scrubbing of free text (e.g. exception messages) before logging.
  static String scrub(String text) {
    var result = text;
    for (final pattern in _patterns) {
      result = result.replaceAllMapped(pattern, (m) => '${m[1]}$mask');
    }
    return result;
  }
}
