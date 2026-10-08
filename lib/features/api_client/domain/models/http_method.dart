enum HttpMethod {
  get('GET'),
  post('POST'),
  put('PUT'),
  patch('PATCH'),
  delete('DELETE'),
  head('HEAD'),
  options('OPTIONS');

  const HttpMethod(this.value);

  final String value;

  bool get allowsBody => this != HttpMethod.get && this != HttpMethod.head;

  static HttpMethod parse(String? raw, {HttpMethod fallback = HttpMethod.get}) {
    final upper = raw?.trim().toUpperCase();
    for (final m in values) {
      if (m.value == upper) return m;
    }
    return fallback;
  }

  static HttpMethod? tryParse(String? raw) {
    final upper = raw?.trim().toUpperCase();
    for (final m in values) {
      if (m.value == upper) return m;
    }
    return null;
  }
}
