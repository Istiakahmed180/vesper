import 'dart:convert';

import '../models/api_response.dart';
import '../models/variable_extraction.dart';

/// Result of one extraction rule.
class ExtractedValue {
  const ExtractedValue(this.rule, this.value, [this.error]);

  final VariableExtraction rule;

  /// Null when nothing was found ([error] says why).
  final String? value;
  final String? error;
}

/// Reads values out of a response for [VariableExtraction] rules.
class ResponseExtractor {
  const ResponseExtractor();

  List<ExtractedValue> extract(
    ApiResponse response,
    List<VariableExtraction> rules,
  ) {
    Object? json;
    var parsed = false;
    Object? parseJson() {
      if (!parsed) {
        parsed = true;
        try {
          json = jsonDecode(response.bodyText);
        } on FormatException {
          json = null;
        }
      }
      return json;
    }

    return [
      for (final rule in rules.where((r) => r.isActive))
        switch (rule.source) {
          ExtractionSource.header => _fromHeader(response, rule),
          ExtractionSource.jsonBody => _fromJson(parseJson(), rule),
        },
    ];
  }

  ExtractedValue _fromHeader(ApiResponse response, VariableExtraction rule) {
    final value = response.header(rule.path.trim());
    return value == null
        ? ExtractedValue(rule, null, 'Header "${rule.path}" not in response')
        : ExtractedValue(rule, value);
  }

  ExtractedValue _fromJson(Object? json, VariableExtraction rule) {
    if (json == null) {
      return ExtractedValue(rule, null, 'The response is not JSON');
    }
    final value = readPath(json, rule.path);
    if (value == null) {
      return ExtractedValue(rule, null, '"${rule.path}" not found in the body');
    }
    return ExtractedValue(rule, value is String ? value : jsonEncode(value));
  }

  static final _segment = RegExp(
    r'''([^.\[\]]+)|\[(\d+)\]|\[['"]([^'"]+)['"]\]''',
  );

  /// Follows a path like `data.items[0].id`, `$.token` or `['a b'].c`.
  /// Returns null when any part is missing.
  static Object? readPath(Object? json, String path) {
    var p = path.trim();
    if (p.startsWith(r'$')) p = p.substring(1);
    if (p.startsWith('.')) p = p.substring(1);
    if (p.isEmpty) return json;
    Object? current = json;
    for (final m in _segment.allMatches(p)) {
      final key = m.group(1) ?? m.group(3);
      final index = m.group(2);
      if (index != null || (key != null && current is List)) {
        final i = int.tryParse(index ?? key!);
        if (current is! List || i == null || i < 0 || i >= current.length) {
          return null;
        }
        current = current[i];
      } else if (current is Map && current.containsKey(key)) {
        current = current[key];
      } else {
        return null;
      }
    }
    return current;
  }
}
