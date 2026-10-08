/// Defensive accessors for untyped JSON (persisted columns, imports).
/// They never throw on wrong types; they fall back to defaults instead.
typedef JsonMap = Map<String, Object?>;

extension JsonRead on JsonMap {
  String str(String key, [String fallback = '']) {
    final v = this[key];
    return v is String ? v : (v == null ? fallback : '$v');
  }

  String? strOrNull(String key) {
    final v = this[key];
    return v is String ? v : null;
  }

  bool boolean(String key, [bool fallback = false]) {
    final v = this[key];
    return v is bool ? v : fallback;
  }

  int integer(String key, [int fallback = 0]) {
    final v = this[key];
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? fallback;
    return fallback;
  }

  int? intOrNull(String key) {
    final v = this[key];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return null;
  }

  JsonMap obj(String key) {
    final v = this[key];
    return v is Map ? v.cast<String, Object?>() : <String, Object?>{};
  }

  JsonMap? objOrNull(String key) {
    final v = this[key];
    return v is Map ? v.cast<String, Object?>() : null;
  }

  List<JsonMap> objList(String key) {
    final v = this[key];
    if (v is! List) return const [];
    return [
      for (final item in v)
        if (item is Map) item.cast<String, Object?>(),
    ];
  }

  List<Object?> list(String key) {
    final v = this[key];
    return v is List ? v.cast<Object?>() : const [];
  }
}
