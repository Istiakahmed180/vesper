import 'environment_models.dart';

abstract class EnvironmentRepository {
  /// Emits all environments (globals first) with secret values hydrated from
  /// the vault. Creates the globals environment if missing.
  Stream<List<Environment>> watchEnvironments();

  Future<Environment> createEnvironment(
    String name, {
    List<EnvVariable> variables = const [],
  });

  /// Persists the environment, routing secret values to the vault.
  Future<void> saveEnvironment(Environment environment);
  Future<void> deleteEnvironment(String id);
  Future<Environment> duplicateEnvironment(String id);
}
