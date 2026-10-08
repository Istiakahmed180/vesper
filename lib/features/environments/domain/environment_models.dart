import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import '../../../core/utils/id.dart';
import '../../../core/utils/json_read.dart';
import '../../api_client/domain/services/variable_resolver.dart';

@immutable
class EnvVariable {
  EnvVariable({
    String? id,
    this.key = '',
    this.value = '',
    this.enabled = true,
    this.isSecret = false,
  }) : id = id ?? newId();

  final String id;
  final String key;
  final String value;
  final bool enabled;
  final bool isSecret;

  bool get isActive => enabled && key.trim().isNotEmpty;

  EnvVariable copyWith({
    String? key,
    String? value,
    bool? enabled,
    bool? isSecret,
  }) => EnvVariable(
    id: id,
    key: key ?? this.key,
    value: value ?? this.value,
    enabled: enabled ?? this.enabled,
    isSecret: isSecret ?? this.isSecret,
  );

  JsonMap toJson({bool includeSecrets = false}) => {
    'key': key,
    'value': isSecret && !includeSecrets ? '' : value,
    'enabled': enabled,
    if (isSecret) 'secret': true,
  };

  factory EnvVariable.fromJson(JsonMap json) => EnvVariable(
    key: json.str('key'),
    value: json.str('value'),
    enabled: json.boolean('enabled', true),
    isSecret: json.boolean('secret'),
  );

  @override
  bool operator ==(Object other) =>
      other is EnvVariable &&
      other.id == id &&
      other.key == key &&
      other.value == value &&
      other.enabled == enabled &&
      other.isSecret == isSecret;

  @override
  int get hashCode => Object.hash(id, key, value, enabled, isSecret);
}

@immutable
class Environment {
  Environment({
    String? id,
    required this.name,
    this.variables = const [],
    this.isGlobal = false,
    this.sortOrder = 0,
  }) : id = id ?? newId();

  final String id;
  final String name;
  final List<EnvVariable> variables;
  final bool isGlobal;
  final int sortOrder;

  Environment copyWith({
    String? name,
    List<EnvVariable>? variables,
    int? sortOrder,
  }) => Environment(
    id: id,
    name: name ?? this.name,
    variables: variables ?? this.variables,
    isGlobal: isGlobal,
    sortOrder: sortOrder ?? this.sortOrder,
  );

  Map<String, VariableValue> toScope(VariableSource source) => {
    for (final v in variables)
      if (v.isActive)
        v.key.trim(): VariableValue(v.value, source, isSecret: v.isSecret),
  };

  static const _eq = ListEquality<EnvVariable>();

  bool sameContentAs(Environment other) =>
      name == other.name && _eq.equals(variables, other.variables);
}
