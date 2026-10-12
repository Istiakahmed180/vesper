import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../../../core/di/app_providers.dart';
import '../../../core/security/redactor.dart';
import '../../api_client/domain/models/api_request.dart';
import '../../api_client/domain/models/api_response.dart';
import '../../api_client/domain/models/variable_extraction.dart';
import '../../api_client/domain/services/response_extractor.dart';
import '../../environments/domain/environment_models.dart';
import '../../environments/presentation/environment_providers.dart';

/// What happened to one "Set variables" rule, shown under the response.
class ExtractionNote {
  const ExtractionNote(this.message, {this.ok = true});
  final String message;
  final bool ok;
}

/// Applies the request's "Set variables" rules to a successful response:
/// writes the values into the active environment, the collection or the
/// Globals and saves them.
Future<List<ExtractionNote>> applyExtractions(
  Ref ref,
  ApiRequest request,
  ApiResponse response,
) async {
  final rules = request.options.extractions.where((r) => r.isActive).toList();
  if (rules.isEmpty) return const [];
  if (response.statusCode < 200 || response.statusCode >= 300) {
    return const [
      ExtractionNote(
        'Variables were not updated: the response was not successful.',
        ok: false,
      ),
    ];
  }

  final notes = <ExtractionNote>[];
  final values = <ExtractionTarget, Map<String, String>>{};
  for (final result in const ResponseExtractor().extract(response, rules)) {
    final value = result.value;
    if (value == null) {
      notes.add(
        ExtractionNote('${result.rule.variable}: ${result.error}', ok: false),
      );
    } else {
      values.putIfAbsent(
        result.rule.target,
        () => {},
      )[result.rule.variable.trim()] = value;
    }
  }

  for (final MapEntry(key: target, value: set) in values.entries) {
    notes.add(
      await setVariables(ref.read, target, request.collectionId, set),
    );
  }
  return notes;
}

/// Reads a provider; both `Ref.read` and `WidgetRef.read` fit.
typedef ProviderRead = T Function<T>(ProviderListenable<T> provider);

/// Writes [set] (name → value) into the active environment, the collection
/// [collectionId] or the Globals, keeping other variables, and saves it.
Future<ExtractionNote> setVariables(
  ProviderRead read,
  ExtractionTarget target,
  String? collectionId,
  Map<String, String> set,
) async {
  final names = set.keys.join(', ');
  switch (target) {
    case ExtractionTarget.environment || ExtractionTarget.globals:
      final env = target == ExtractionTarget.environment
          ? read(activeEnvironmentProvider)
          : read(globalsEnvironmentProvider);
      if (env == null) {
        return ExtractionNote(
          '$names not set: select an environment first.',
          ok: false,
        );
      }
      await read(
        environmentRepositoryProvider,
      ).saveEnvironment(env.copyWith(variables: _merge(env.variables, set)));
      return ExtractionNote('Set $names in ${env.name}');
    case ExtractionTarget.collection:
      final repo = read(collectionRepositoryProvider);
      final settings = collectionId == null
          ? null
          : await repo.getSettings(collectionId);
      if (collectionId == null || settings == null) {
        return ExtractionNote(
          '$names not set: save the request in a collection first.',
          ok: false,
        );
      }
      await repo.saveSettings(
        collectionId,
        settings.copyWith(variables: _merge(settings.variables, set)),
      );
      return ExtractionNote('Set $names in the collection variables');
  }
}

List<EnvVariable> _merge(List<EnvVariable> current, Map<String, String> set) {
  final merged = [
    for (final v in current)
      set.containsKey(v.key) ? v.copyWith(value: set[v.key]) : v,
  ];
  for (final MapEntry(:key, :value) in set.entries) {
    if (!current.any((v) => v.key == key)) {
      merged.add(
        EnvVariable(
          key: key,
          value: value,
          isSecret: Redactor.isSensitiveKey(key),
        ),
      );
    }
  }
  return merged;
}
