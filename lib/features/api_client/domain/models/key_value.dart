import 'package:flutter/foundation.dart';

import '../../../../core/utils/id.dart';
import '../../../../core/utils/json_read.dart';

/// A row in a params / headers / url-encoded table.
@immutable
class KeyValue {
  KeyValue({
    String? id,
    this.key = '',
    this.value = '',
    this.enabled = true,
    this.description = '',
  }) : id = id ?? newId();

  final String id;
  final String key;
  final String value;
  final bool enabled;
  final String description;

  bool get isEmpty => key.isEmpty && value.isEmpty && description.isEmpty;
  bool get isActive => enabled && key.isNotEmpty;

  KeyValue copyWith({
    String? key,
    String? value,
    bool? enabled,
    String? description,
  }) => KeyValue(
    id: id,
    key: key ?? this.key,
    value: value ?? this.value,
    enabled: enabled ?? this.enabled,
    description: description ?? this.description,
  );

  JsonMap toJson() => {
    'id': id,
    'key': key,
    'value': value,
    'enabled': enabled,
    if (description.isNotEmpty) 'description': description,
  };

  factory KeyValue.fromJson(JsonMap json) => KeyValue(
    id: json.strOrNull('id'),
    key: json.str('key'),
    value: json.str('value'),
    enabled: json.boolean('enabled', true),
    description: json.str('description'),
  );

  @override
  bool operator ==(Object other) =>
      other is KeyValue &&
      other.id == id &&
      other.key == key &&
      other.value == value &&
      other.enabled == enabled &&
      other.description == description;

  @override
  int get hashCode => Object.hash(id, key, value, enabled, description);
}

extension KeyValueList on List<KeyValue> {
  List<KeyValue> get active => where((e) => e.isActive).toList();

  List<JsonMap> toJson() => [for (final e in this) e.toJson()];

  static List<KeyValue> fromJson(List<JsonMap> json) => [
    for (final e in json) KeyValue.fromJson(e),
  ];
}
