import '../models/key_value.dart';

/// URL helpers that work on raw, unresolved text (which may contain
/// `{{variables}}` and therefore cannot go through [Uri.parse]).
class UrlParts {
  const UrlParts(this.base, this.query, this.fragment);

  final String base;

  /// Query without the leading `?`; null when there is no `?`.
  final String? query;

  /// Fragment without the leading `#`; null when there is no `#`.
  final String? fragment;

  static UrlParts split(String url) {
    var rest = url;
    String? fragment;
    final hash = rest.indexOf('#');
    if (hash != -1) {
      fragment = rest.substring(hash + 1);
      rest = rest.substring(0, hash);
    }
    final q = rest.indexOf('?');
    if (q == -1) return UrlParts(rest, null, fragment);
    return UrlParts(rest.substring(0, q), rest.substring(q + 1), fragment);
  }
}

class UrlUtils {
  const UrlUtils._();

  /// Parses `a=1&b=2` into raw (not percent-decoded) pairs.
  static List<(String, String)> parseQuery(String query) {
    if (query.isEmpty) return const [];
    return [
      for (final part in query.split('&'))
        if (part.isNotEmpty)
          switch (part.indexOf('=')) {
            -1 => (part, ''),
            final i => (part.substring(0, i), part.substring(i + 1)),
          },
    ];
  }

  /// Rebuilds the parameter table after the user edited the URL. Rows that are
  /// disabled are not part of the URL and therefore preserved; enabled rows are
  /// replaced by what the URL now contains, reusing row ids by position so the
  /// table does not flicker.
  static List<KeyValue> paramsFromUrl(String url, List<KeyValue> previous) {
    final query = UrlParts.split(url).query;
    final pairs = query == null
        ? const <(String, String)>[]
        : parseQuery(query);
    final enabledPrev = previous.where((p) => p.enabled).toList();
    final result = <KeyValue>[];
    for (var i = 0; i < pairs.length; i++) {
      final (key, value) = pairs[i];
      final prev = i < enabledPrev.length ? enabledPrev[i] : null;
      result.add(
        prev != null
            ? prev.copyWith(key: key, value: value)
            : KeyValue(key: key, value: value),
      );
    }
    // Re-insert disabled rows at their original relative positions.
    for (var i = 0; i < previous.length; i++) {
      final p = previous[i];
      if (!p.enabled) result.insert(i.clamp(0, result.length), p);
    }
    return result;
  }

  /// Rebuilds the URL's query string from the parameter table.
  static String urlWithParams(String url, List<KeyValue> params) {
    final parts = UrlParts.split(url);
    final enabled = params.where(
      (p) => p.enabled && (p.key.isNotEmpty || p.value.isNotEmpty),
    );
    final query = enabled
        .map((p) => p.value.isEmpty ? p.key : '${p.key}=${p.value}')
        .join('&');
    final buffer = StringBuffer(parts.base);
    if (query.isNotEmpty) buffer.write('?$query');
    if (parts.fragment != null) buffer.write('#${parts.fragment}');
    return buffer.toString();
  }

  static const _unreserved =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

  /// Percent-encodes a query component while preserving existing valid
  /// `%XX` escapes, so values the user already encoded are not double-encoded.
  static String encodeQueryComponent(String input, {bool isKey = false}) {
    final keep = isKey ? r"!$'()*,;:@/?+" : r"!$'()*,;:@/?+=";
    final out = StringBuffer();
    final bytes = input.codeUnits;
    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      if (ch == '%' &&
          i + 2 < input.length &&
          _isHex(input[i + 1]) &&
          _isHex(input[i + 2])) {
        out.write(ch);
        continue;
      }
      if (_unreserved.contains(ch) || keep.contains(ch)) {
        out.write(ch);
        continue;
      }
      if (bytes[i] < 128) {
        out.write(
          '%${bytes[i].toRadixString(16).toUpperCase().padLeft(2, '0')}',
        );
      } else {
        out.write(Uri.encodeComponent(_takeCodePoint(input, i)));
        if (_isHighSurrogate(bytes[i])) i++;
      }
    }
    return out.toString();
  }

  static final _hex = RegExp(r'^[0-9a-fA-F]$');
  static bool _isHex(String c) => _hex.hasMatch(c);
  static bool _isHighSurrogate(int u) => u >= 0xD800 && u <= 0xDBFF;
  static String _takeCodePoint(String s, int i) =>
      _isHighSurrogate(s.codeUnitAt(i)) && i + 1 < s.length
      ? s.substring(i, i + 2)
      : s[i];

  /// Builds the final URL to send from an already-resolved URL without its
  /// query and the resolved, enabled query pairs.
  static String buildRequestUrl(
    String resolvedBase,
    List<(String, String)> query,
  ) {
    final parts = UrlParts.split(resolvedBase);
    var base = parts.base.trim();
    if (base.isNotEmpty && !hasScheme(base)) base = 'http://$base';
    final q = query
        .map(
          (p) => p.$2.isEmpty
              ? encodeQueryComponent(p.$1, isKey: true)
              : '${encodeQueryComponent(p.$1, isKey: true)}=${encodeQueryComponent(p.$2)}',
        )
        .join('&');
    final buffer = StringBuffer(_encodePath(base));
    if (q.isNotEmpty) buffer.write('?$q');
    if (parts.fragment != null && parts.fragment!.isNotEmpty) {
      buffer.write('#${parts.fragment}');
    }
    return buffer.toString();
  }

  static bool hasScheme(String url) =>
      RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(url);

  /// Encodes characters that are illegal in a URL path (spaces, unicode) while
  /// leaving reserved characters and existing escapes intact.
  static String _encodePath(String url) {
    final out = StringBuffer();
    for (var i = 0; i < url.length; i++) {
      final ch = url[i];
      final code = url.codeUnitAt(i);
      if (ch == '%' &&
          i + 2 < url.length &&
          _isHex(url[i + 1]) &&
          _isHex(url[i + 2])) {
        out.write(ch);
      } else if (code <= 0x20 || code >= 0x7F || '"<>\\^`{|}'.contains(ch)) {
        out.write(Uri.encodeComponent(_takeCodePoint(url, i)));
        if (_isHighSurrogate(code)) i++;
      } else {
        out.write(ch);
      }
    }
    return out.toString();
  }
}
