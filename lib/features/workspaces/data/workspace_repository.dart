import 'package:drift/drift.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/security/secret_vault.dart';
import '../../../core/storage/app_database.dart';
import '../../../core/utils/id.dart';
import '../../collections/data/drift_collection_repository.dart';
import '../../settings/data/settings_repository.dart';
import '../domain/workspace.dart';

class WorkspaceRepository {
  WorkspaceRepository(this._db, this._vault);

  final AppDatabase _db;
  final SecretVault _vault;

  Stream<List<Workspace>> watchAll() =>
      (_db.select(_db.workspaces)..orderBy([
            (w) => OrderingTerm.asc(w.sortOrder),
            (w) => OrderingTerm.asc(w.createdAt),
          ]))
          .watch()
          .map((rows) => rows.map(_fromRow).toList());

  Future<Workspace?> get(String id) async {
    final row = await (_db.select(
      _db.workspaces,
    )..where((w) => w.id.equals(id))).getSingleOrNull();
    return row == null ? null : _fromRow(row);
  }

  static Workspace _fromRow(WorkspaceRow row) => Workspace(
    id: row.id,
    name: row.name,
    sortOrder: row.sortOrder,
    activeEnvironmentId: row.activeEnvironmentId,
  );

  Future<Workspace> create(String name) async {
    final max = _db.workspaces.sortOrder.max();
    final top = await (_db.selectOnly(
      _db.workspaces,
    )..addColumns([max])).getSingle();
    final workspace = Workspace(
      id: newId(),
      name: _validName(name),
      sortOrder: (top.read(max) ?? 0) + 1,
    );
    final now = DateTime.now();
    await _db
        .into(_db.workspaces)
        .insert(
          WorkspacesCompanion.insert(
            id: workspace.id,
            name: workspace.name,
            sortOrder: Value(workspace.sortOrder),
            createdAt: now,
            updatedAt: now,
          ),
        );
    return workspace;
  }

  Future<void> rename(String id, String name) =>
      (_db.update(_db.workspaces)..where((w) => w.id.equals(id))).write(
        WorkspacesCompanion(
          name: Value(_validName(name)),
          updatedAt: Value(DateTime.now()),
        ),
      );

  Future<void> setActiveEnvironment(String id, String? environmentId) =>
      (_db.update(_db.workspaces)..where((w) => w.id.equals(id))).write(
        WorkspacesCompanion(activeEnvironmentId: Value(environmentId)),
      );

  /// Deletes the workspace with everything in it, including vault secrets.
  /// The default workspace always stays.
  Future<void> delete(String id) async {
    if (id == defaultWorkspaceId) {
      throw const ValidationFailure(
        'The default workspace cannot be deleted. You can rename it instead.',
      );
    }
    final collections = DriftCollectionRepository(_db, _vault, workspaceId: id);
    final collectionIds =
        await (_db.selectOnly(_db.collections)
              ..addColumns([_db.collections.id])
              ..where(_db.collections.workspaceId.equals(id)))
            .map((r) => r.read(_db.collections.id)!)
            .get();
    for (final c in collectionIds) {
      await collections.deleteCollection(c);
    }

    final envIds =
        await (_db.selectOnly(_db.environments)
              ..addColumns([_db.environments.id])
              ..where(_db.environments.workspaceId.equals(id)))
            .map((r) => r.read(_db.environments.id)!)
            .get();
    final settings = SettingsRepository(_db);
    await _db.transaction(() async {
      await (_db.delete(
        _db.environments,
      )..where((e) => e.workspaceId.equals(id))).go();
      await (_db.delete(
        _db.historyEntries,
      )..where((h) => h.workspaceId.equals(id))).go();
      await settings.remove(SettingsRepository.tabsKey(id));
      await settings.remove(SettingsRepository.syncTargetKey(id));
      await (_db.delete(_db.workspaces)..where((w) => w.id.equals(id))).go();
    });
    final prefixes = envIds.map(VaultKeys.environmentPrefix).toList();
    if (prefixes.isNotEmpty) {
      await _vault.deleteWhere((k) => prefixes.any(k.startsWith));
    }
  }

  static String _validName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const ValidationFailure('Enter a workspace name.');
    }
    return trimmed;
  }
}
