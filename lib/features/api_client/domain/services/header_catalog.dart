/// Common HTTP request headers and typical values, for autocomplete.
class HeaderCatalog {
  const HeaderCatalog._();

  /// Header name → short description.
  static const headers = <String, String>{
    'Accept': 'Media types the client accepts',
    'Accept-Charset': 'Character sets the client accepts',
    'Accept-Encoding': 'Content encodings the client accepts',
    'Accept-Language': 'Preferred languages',
    'Access-Control-Request-Headers': 'Headers of a CORS preflight request',
    'Access-Control-Request-Method': 'Method of a CORS preflight request',
    'Authorization': 'Credentials (prefer the Authorization tab)',
    'Cache-Control': 'Caching directives',
    'Connection': 'Keep the connection open or close it',
    'Content-Disposition': 'How the content is presented',
    'Content-Encoding': 'Encoding applied to the body',
    'Content-Language': 'Language of the body',
    'Content-Length': 'Size of the body in bytes',
    'Content-MD5': 'MD5 digest of the body',
    'Content-Type': 'Media type of the body',
    'Cookie': 'Cookies sent to the server',
    'Date': 'When the request was sent',
    'DNT': 'Do Not Track preference',
    'Expect': 'Expectations, e.g. 100-continue',
    'Forwarded': 'Proxy information',
    'From': 'Email of the person making the request',
    'Host': 'Server host and port',
    'If-Match': 'Only if the ETag matches',
    'If-Modified-Since': 'Only if modified since a date',
    'If-None-Match': 'Only if the ETag does not match',
    'If-Range': 'Range request condition',
    'If-Unmodified-Since': 'Only if not modified since a date',
    'Keep-Alive': 'Keep-alive parameters',
    'Max-Forwards': 'Limit for proxies (TRACE/OPTIONS)',
    'Origin': 'Where a cross-origin request comes from',
    'Pragma': 'Legacy caching directive',
    'Prefer': 'Preferred server behaviour',
    'Proxy-Authorization': 'Credentials for a proxy',
    'Range': 'Request part of a resource',
    'Referer': 'Page the request comes from',
    'TE': 'Transfer encodings the client accepts',
    'Upgrade': 'Switch to another protocol',
    'Upgrade-Insecure-Requests': 'Prefer an HTTPS response',
    'User-Agent': 'Client software',
    'Via': 'Proxies the request went through',
    'X-API-Key': 'API key',
    'X-Correlation-ID': 'Correlates related requests',
    'X-CSRF-Token': 'Cross-site request forgery token',
    'X-Forwarded-For': 'Original client IP behind proxies',
    'X-Forwarded-Host': 'Original host behind proxies',
    'X-Forwarded-Proto': 'Original protocol behind proxies',
    'X-HTTP-Method-Override': 'Override the HTTP method',
    'X-Request-ID': 'Unique request identifier',
    'X-Requested-With': 'Marks AJAX requests',
  };

  /// Typical values per header (lowercase name).
  static const values = <String, List<String>>{
    'accept': [
      '*/*',
      'application/json',
      'application/xml',
      'text/html',
      'text/plain',
      'application/octet-stream',
    ],
    'accept-encoding': ['gzip', 'gzip, deflate, br', 'identity'],
    'accept-language': ['en-US,en;q=0.9', 'en', 'bn-BD,bn;q=0.9'],
    'authorization': ['Bearer {{token}}', 'Basic {{credentials}}'],
    'cache-control': [
      'no-cache',
      'no-store',
      'max-age=0',
      'must-revalidate',
      'public, max-age=3600',
    ],
    'connection': ['keep-alive', 'close'],
    'content-encoding': ['gzip', 'deflate', 'br'],
    'content-type': [
      'application/json',
      'application/x-www-form-urlencoded',
      'multipart/form-data',
      'text/plain',
      'application/xml',
      'text/html',
      'application/octet-stream',
      'application/graphql',
    ],
    'dnt': ['1', '0'],
    'expect': ['100-continue'],
    'pragma': ['no-cache'],
    'prefer': ['return=representation', 'return=minimal', 'respond-async'],
    'upgrade-insecure-requests': ['1'],
    'x-requested-with': ['XMLHttpRequest'],
  };

  /// Header names matching [text] (prefix matches first), excluding an exact
  /// match. Empty text lists the most used headers.
  static List<(String, String)> names(String text, {int limit = 10}) {
    final q = text.trim().toLowerCase();
    if (q.contains('{{')) return const [];
    final matches =
        headers.entries.where((e) {
          final n = e.key.toLowerCase();
          return n != q && n.contains(q);
        }).toList()..sort((a, b) {
          final ap = a.key.toLowerCase().startsWith(q) ? 0 : 1;
          final bp = b.key.toLowerCase().startsWith(q) ? 0 : 1;
          return ap != bp ? ap - bp : a.key.compareTo(b.key);
        });
    if (q.isEmpty) {
      const popular = [
        'Content-Type',
        'Accept',
        'Authorization',
        'Cache-Control',
        'Accept-Language',
        'Accept-Encoding',
        'User-Agent',
        'Cookie',
        'Origin',
        'X-API-Key',
      ];
      return [for (final n in popular) (n, headers[n]!)];
    }
    return [for (final e in matches.take(limit)) (e.key, e.value)];
  }

  /// Typical values of [header] matching [text], excluding an exact match.
  static List<String> valuesFor(String header, String text) {
    final q = text.trim().toLowerCase();
    return [
      for (final v in values[header.trim().toLowerCase()] ?? const <String>[])
        if (v.toLowerCase() != q && v.toLowerCase().contains(q)) v,
    ];
  }
}
