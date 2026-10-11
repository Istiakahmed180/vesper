import 'dart:math';

import '../../../../core/utils/id.dart';

/// Result of resolving `{{variables}}` in a piece of text.
class ResolvedText {
  const ResolvedText(this.value, this.unresolved);

  final String value;
  final Set<String> unresolved;
}

/// Where a variable value came from; used for previews and tooltips.
enum VariableSource { environment, collection, global, dynamic }

class VariableValue {
  const VariableValue(this.value, this.source, {this.isSecret = false});

  final String value;
  final VariableSource source;
  final bool isSecret;
}

/// Resolves `{{name}}` placeholders. Scopes are searched in priority order
/// (environment, then the request's collection, then globals). Values may reference other variables; nesting
/// is resolved up to [maxDepth] to avoid infinite loops on cycles.
class VariableResolver {
  VariableResolver({
    this.environment = const {},
    this.collection = const {},
    this.globals = const {},
    Random? random,
    DateTime Function()? clock,
  }) : _random = random ?? Random.secure(),
       _clock = clock ?? DateTime.now;

  static final pattern = RegExp(r'\{\{\s*([^{}\s]+?)\s*\}\}');
  static const maxDepth = 6;

  final Map<String, VariableValue> environment;
  final Map<String, VariableValue> collection;
  final Map<String, VariableValue> globals;
  final Random _random;
  final DateTime Function() _clock;

  static const dynamicVariables = {
    r'$guid': 'A random UUID v4',
    r'$timestamp': 'Current Unix timestamp in seconds',
    r'$isoTimestamp': 'Current ISO-8601 timestamp (UTC)',
    r'$randomInt': 'Random integer between 0 and 1000',
  };

  VariableValue? lookup(String name) {
    if (name.startsWith(r'$')) {
      final value = _dynamic(name);
      return value == null
          ? null
          : VariableValue(value, VariableSource.dynamic);
    }
    return environment[name] ?? collection[name] ?? globals[name];
  }

  String? _dynamic(String name) => switch (name) {
    r'$guid' => newId(),
    r'$timestamp' => (_clock().millisecondsSinceEpoch ~/ 1000).toString(),
    r'$isoTimestamp' => _clock().toUtc().toIso8601String(),
    r'$randomInt' => _random.nextInt(1001).toString(),
    _ => null,
  };

  ResolvedText resolve(String input) {
    if (!input.contains('{{')) return ResolvedText(input, const {});
    final unresolved = <String>{};
    var current = input;
    for (var depth = 0; depth < maxDepth; depth++) {
      var replaced = false;
      current = current.replaceAllMapped(pattern, (m) {
        final name = m.group(1)!;
        final value = lookup(name);
        if (value == null) {
          unresolved.add(name);
          return m.group(0)!;
        }
        replaced = true;
        return value.value;
      });
      if (!replaced || !current.contains('{{')) break;
    }
    // A variable resolved later in the loop may have been flagged earlier.
    unresolved.removeWhere((n) => lookup(n) != null);
    return ResolvedText(current, unresolved);
  }

  String call(String input) => resolve(input).value;

  /// This resolver with [scope] as the collection variables.
  VariableResolver withCollection(Map<String, VariableValue> scope) =>
      VariableResolver(
        environment: environment,
        collection: scope,
        globals: globals,
        random: _random,
        clock: _clock,
      );

  /// Names referenced in [input], in order of appearance.
  static List<String> referencedNames(String input) => [
    for (final m in pattern.allMatches(input)) m.group(1)!,
  ];
}
