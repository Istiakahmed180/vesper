import 'package:drift/drift.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/security/secret_vault.dart';
import '../../../core/storage/app_database.dart';
import '../domain/environment_models.dart';
import '../domain/environment_repository.dart';

class DriftEnvironmentRepository implements EnvironmentRepository {
  DriftEnvironmentRepository(this._db, this._vault);

  final AppDatabase _db;
  final SecretVault _vault;
  bool _globalsEnsured = false;

  @override
  Stream<List<Environment>> watchEnvironments() async* {
    await _ensureGlobals();
    yield* _db
        .customSelect(
          'SELECT 1 AS environments_tick',
          readsFrom: {_db.environments, _db.envVariables},
        )
        .watch()
        .asyncMap((_) => _loadAll());
  }

  Future<void> _ensureGlobals() async {
    if (_globalsEnsured) return;
    final existing = await (_db.select(
      _db.environments,
    )..where((e) => e.isGlobal.equals(true))).getSingleOrNull();
    if (existing == null) {
      final now = DateTime.now();
      final globals = Environment(name: 'Globals', isGlobal: true);
      await _db
          .into(_db.environments)
          .insert(
            EnvironmentsCompanion.insert(
              id: globals.id,
              name: globals.name,
              isGlobal: const Value(true),
              sortOrder: const Value(-1),
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
    _globalsEnsured = true;
  }

  Future<List<Environment>> _loadAll() async {
    final envs =
        await (_db.select(_db.environments)..orderBy([
              (e) => OrderingTerm.desc(e.isGlobal),
              (e) => OrderingTerm.asc(e.sortOrder),
              (e) => OrderingTerm.asc(e.createdAt),
            ]))
            .get();
    final vars = await (_db.select(
      _db.envVariables,
    )..orderBy([(v) => OrderingTerm.asc(v.sortOrder)])).get();
    final byEnv = <String, List<EnvVariableRow>>{};
    for (final v in vars) {
      byEnv.putIfAbsent(v.environmentId, () => []).add(v);
    }
    final result = <Environment>[];
    for (final e in envs) {
      final variables = <EnvVariable>[];
      for (final v in byEnv[e.id] ?? const <EnvVariableRow>[]) {
        final value = v.isSecret
            ? (await _vault.read(VaultKeys.envVariable(e.id, v.id)) ?? '')
            : v.value;
        variables.add(
          EnvVariable(
            id: v.id,
            key: v.key,
            value: value,
            enabled: v.enabled,
            isSecret: v.isSecret,
          ),
        );
      }
      result.add(
        Environment(
          id: e.id,
          name: e.name,
          isGlobal: e.isGlobal,
          sortOrder: e.sortOrder,
          variables: variables,
        ),
      );
    }
    return result;
  }

  @override
  Future<Environment> createEnvironment(
    String name, {
    List<EnvVariable> variables = const [],
  }) async {
    final max = _db.environments.sortOrder.max();
    final row = await (_db.selectOnly(
      _db.environments,
    )..addColumns([max])).getSingle();
    final env = Environment(
      name: name.trim().isEmpty ? 'New environment' : name.trim(),
      sortOrder: (row.read(max) ?? -1) + 1,
      variables: variables,
    );
    final now = DateTime.now();
    await _db
        .into(_db.environments)
        .insert(
          EnvironmentsCompanion.insert(
            id: env.id,
            name: env.name,
            sortOrder: Value(env.sortOrder),
            createdAt: now,
            updatedAt: now,
          ),
        );
    if (variables.isNotEmpty) await saveEnvironment(env);
    return env;
  }

  @override
  Future<void> saveEnvironment(Environment environment) async {
    final exists = await (_db.select(
      _db.environments,
    )..where((e) => e.id.equals(environment.id))).getSingleOrNull();
    if (exists == null) {
      throw const StorageFailure('The environment no longer exists.');
    }
    await _db.transaction(() async {
      await (_db.update(
        _db.environments,
      )..where((e) => e.id.equals(environment.id))).write(
        EnvironmentsCompanion(
          name: Value(
            environment.name.trim().isEmpty
                ? exists.name
                : environment.name.trim(),
          ),
          updatedAt: Value(DateTime.now()),
        ),
      );
      await (_db.delete(
        _db.envVariables,
      )..where((v) => v.environmentId.equals(environment.id))).go();
      var order = 0;
      for (final v in environment.variables) {
        if (v.key.isEmpty && v.value.isEmpty) continue;
        await _db
            .into(_db.envVariables)
            .insert(
              EnvVariablesCompanion.insert(
                id: v.id,
                environmentId: environment.id,
                key: v.key,
                value: Value(v.isSecret ? '' : v.value),
                enabled: Value(v.enabled),
                isSecret: Value(v.isSecret),
                sortOrder: Value(order++),
              ),
            );
      }
    });

    // Vault: write current secrets, drop entries for removed/non-secret vars.
    final secretKeys = <String>{};
    for (final v in environment.variables.where((v) => v.isSecret)) {
      final key = VaultKeys.envVariable(environment.id, v.id);
      secretKeys.add(key);
      await _vault.write(key, v.value);
    }
    final prefix = VaultKeys.environmentPrefix(environment.id);
    await _vault.deleteWhere(
      (k) => k.startsWith(prefix) && !secretKeys.contains(k),
    );
  }

  @override
  Future<void> deleteEnvironment(String id) async {
    final env = await (_db.select(
      _db.environments,
    )..where((e) => e.id.equals(id))).getSingleOrNull();
    if (env == null) return;
    if (env.isGlobal) {
      throw const ValidationFailure(
        'The Globals environment cannot be deleted.',
      );
    }
    await (_db.delete(_db.environments)..where((e) => e.id.equals(id))).go();
    final prefix = VaultKeys.environmentPrefix(id);
    await _vault.deleteWhere((k) => k.startsWith(prefix));
  }

  @override
  Future<Environment> duplicateEnvironment(String id) async {
    final all = await _loadAll();
    final source = all.where((e) => e.id == id).firstOrNull;
    if (source == null) {
      throw const StorageFailure('The environment no longer exists.');
    }
    return createEnvironment(
      '${source.name} copy',
      variables: [
        for (final v in source.variables)
          EnvVariable(
            key: v.key,
            value: v.value,
            enabled: v.enabled,
            isSecret: v.isSecret,
          ),
      ],
    );
  }
}
