import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../api_client/domain/services/variable_resolver.dart';
import '../../settings/presentation/settings_controller.dart';
import '../domain/environment_models.dart';

final environmentsProvider = StreamProvider<List<Environment>>(
  (ref) => ref.watch(environmentRepositoryProvider).watchEnvironments(),
);

final globalsEnvironmentProvider = Provider<Environment?>((ref) {
  final envs = ref.watch(environmentsProvider).value ?? const [];
  return envs.where((e) => e.isGlobal).firstOrNull;
});

final activeEnvironmentProvider = Provider<Environment?>((ref) {
  final id = ref.watch(settingsProvider.select((s) => s.activeEnvironmentId));
  if (id == null) return null;
  final envs = ref.watch(environmentsProvider).value ?? const [];
  return envs.where((e) => e.id == id && !e.isGlobal).firstOrNull;
});

/// Resolver for the current variable scope (active environment + globals).
final variableResolverProvider = Provider<VariableResolver>((ref) {
  final env = ref.watch(activeEnvironmentProvider);
  final globals = ref.watch(globalsEnvironmentProvider);
  return VariableResolver(
    environment: env?.toScope(VariableSource.environment) ?? const {},
    globals: globals?.toScope(VariableSource.global) ?? const {},
  );
});
