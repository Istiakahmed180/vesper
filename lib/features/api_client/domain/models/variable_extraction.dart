import 'package:flutter/foundation.dart';

import '../../../../core/utils/id.dart';
import '../../../../core/utils/json_read.dart';

/// Where an extracted value is read from.
enum ExtractionSource {
  jsonBody('JSON body'),
  header('Header');

  const ExtractionSource(this.label);
  final String label;
}

/// Where an extracted value is stored.
enum ExtractionTarget {
  environment('Active environment'),
  collection('Collection'),
  globals('Globals');

  const ExtractionTarget(this.label);
  final String label;
}

/// "After a successful response, set variable [variable] to the value at
/// [path]" — a no-code alternative to a post-response script.
@immutable
class VariableExtraction {
  VariableExtraction({
    String? id,
    this.enabled = true,
    this.variable = '',
    this.source = ExtractionSource.jsonBody,
    this.path = '',
    this.target = ExtractionTarget.environment,
  }) : id = id ?? newId();

  final String id;
  final bool enabled;
  final String variable;
  final ExtractionSource source;

  /// JSON path such as `token`, `data.access_token` or `items[0].id`; for a
  /// header source, the header name.
  final String path;
  final ExtractionTarget target;

  bool get isActive =>
      enabled && variable.trim().isNotEmpty && path.trim().isNotEmpty;

  VariableExtraction copyWith({
    bool? enabled,
    String? variable,
    ExtractionSource? source,
    String? path,
    ExtractionTarget? target,
  }) => VariableExtraction(
    id: id,
    enabled: enabled ?? this.enabled,
    variable: variable ?? this.variable,
    source: source ?? this.source,
    path: path ?? this.path,
    target: target ?? this.target,
  );

  JsonMap toJson() => {
    'variable': variable,
    'source': source.name,
    'path': path,
    'target': target.name,
    if (!enabled) 'enabled': false,
  };

  factory VariableExtraction.fromJson(JsonMap json) => VariableExtraction(
    variable: json.str('variable'),
    source:
        ExtractionSource.values
            .where((s) => s.name == json.str('source'))
            .firstOrNull ??
        ExtractionSource.jsonBody,
    path: json.str('path'),
    target:
        ExtractionTarget.values
            .where((t) => t.name == json.str('target'))
            .firstOrNull ??
        ExtractionTarget.environment,
    enabled: json.boolean('enabled', true),
  );

  @override
  bool operator ==(Object other) =>
      other is VariableExtraction &&
      other.id == id &&
      other.enabled == enabled &&
      other.variable == variable &&
      other.source == source &&
      other.path == path &&
      other.target == target;

  @override
  int get hashCode => Object.hash(id, enabled, variable, source, path, target);
}
