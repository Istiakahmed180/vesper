import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../constants/app_constants.dart';

part 'app_database.g.dart';

/// Workspace that always exists; data from before workspaces lands here.
const defaultWorkspaceId = 'default';
const defaultWorkspaceName = 'My Workspace';

/// Top-level container for collections, environments and history.
@DataClassName('WorkspaceRow')
class Workspaces extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  TextColumn get activeEnvironmentId => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('CollectionRow')
class Collections extends Table {
  TextColumn get id => text()();
  TextColumn get workspaceId =>
      text().withDefault(const Constant(defaultWorkspaceId))();
  TextColumn get name => text()();
  TextColumn get description => text().withDefault(const Constant(''))();

  /// Collection authorization without secrets (those are in the vault).
  TextColumn get authJson => text().withDefault(const Constant('{}'))();

  /// Collection variables; secret values are empty here (kept in the vault).
  TextColumn get variablesJson => text().withDefault(const Constant('[]'))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('FolderRow')
class Folders extends Table {
  TextColumn get id => text()();
  TextColumn get collectionId =>
      text().references(Collections, #id, onDelete: KeyAction.cascade)();
  TextColumn get parentId =>
      text().nullable().references(Folders, #id, onDelete: KeyAction.cascade)();
  TextColumn get name => text()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Saved requests. Secret auth fields are NOT stored here; they live in the
/// OS vault under `VaultKeys.requestAuth`.
@DataClassName('RequestRow')
class Requests extends Table {
  TextColumn get id => text()();
  TextColumn get collectionId =>
      text().references(Collections, #id, onDelete: KeyAction.cascade)();
  TextColumn get folderId =>
      text().nullable().references(Folders, #id, onDelete: KeyAction.cascade)();
  TextColumn get name => text()();
  TextColumn get method => text()();
  TextColumn get url => text()();
  TextColumn get paramsJson => text().withDefault(const Constant('[]'))();
  TextColumn get headersJson => text().withDefault(const Constant('[]'))();
  TextColumn get bodyJson => text().withDefault(const Constant('{}'))();
  TextColumn get authJson => text().withDefault(const Constant('{}'))();
  TextColumn get optionsJson => text().withDefault(const Constant('{}'))();
  TextColumn get description => text().withDefault(const Constant(''))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('EnvironmentRow')
class Environments extends Table {
  TextColumn get id => text()();
  TextColumn get workspaceId =>
      text().withDefault(const Constant(defaultWorkspaceId))();
  TextColumn get name => text()();
  BoolColumn get isGlobal => boolean().withDefault(const Constant(false))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Environment variables. For secret variables [value] is always empty and
/// the real value is kept in the OS vault.
@DataClassName('EnvVariableRow')
class EnvVariables extends Table {
  TextColumn get id => text()();
  TextColumn get environmentId =>
      text().references(Environments, #id, onDelete: KeyAction.cascade)();
  TextColumn get key => text()();
  TextColumn get value => text().withDefault(const Constant(''))();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();
  BoolColumn get isSecret => boolean().withDefault(const Constant(false))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Executed requests. [requestJson] is a sanitized snapshot (see
/// HistorySanitizer); response bodies are not persisted.
@DataClassName('HistoryRow')
class HistoryEntries extends Table {
  TextColumn get id => text()();
  TextColumn get workspaceId =>
      text().withDefault(const Constant(defaultWorkspaceId))();
  TextColumn get requestId => text().nullable()();
  TextColumn get method => text()();
  TextColumn get url => text()();
  IntColumn get statusCode => integer().nullable()();
  TextColumn get errorMessage => text().nullable()();
  IntColumn get durationMs => integer().withDefault(const Constant(0))();
  IntColumn get sizeBytes => integer().withDefault(const Constant(0))();
  DateTimeColumn get executedAt => dateTime()();
  TextColumn get requestJson => text()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('SettingRow')
class SettingsEntries extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

/// Last known synchronised state of a local item against a remote file.
@DataClassName('SyncStateRow')
class SyncStates extends Table {
  TextColumn get itemKey => text()();
  TextColumn get remote => text()();
  TextColumn get path => text()();
  TextColumn get remoteSha => text()();
  TextColumn get contentHash => text()();
  DateTimeColumn get syncedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {itemKey, remote};
}

/// Local changes waiting to be uploaded to the cloud, filled by triggers on
/// the synced tables. One row per item; [changedAt] is the latest change.
@DataClassName('OutboxRow')
class SyncOutbox extends Table {
  TextColumn get kind => text()();
  TextColumn get itemId => text()();

  /// UTC ISO-8601 time of the latest local change.
  TextColumn get changedAt => text()();

  @override
  Set<Column<Object>> get primaryKey => {kind, itemId};
}

/// While a row exists here the change-tracking triggers are silent (used when
/// applying cloud changes and when wiping the database).
@DataClassName('SyncFlagRow')
class SyncFlags extends Table {
  TextColumn get name => text()();

  @override
  Set<Column<Object>> get primaryKey => {name};
}

/// Id of a workspace's Globals environment. Deterministic so the same
/// workspace has one Globals on every device.
String globalsEnvironmentId(String workspaceId) => 'globals-$workspaceId';

@DriftDatabase(
  tables: [
    Workspaces,
    Collections,
    Folders,
    Requests,
    Environments,
    EnvVariables,
    HistoryEntries,
    SettingsEntries,
    SyncStates,
    SyncOutbox,
    SyncFlags,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  factory AppDatabase.open() => AppDatabase(
    driftDatabase(
      name: AppConstants.databaseName,
      native: const DriftNativeOptions(
        databaseDirectory: getApplicationSupportDirectory,
      ),
    ),
  );

  /// Bump when the schema changes and add a step in [migration].
  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await _createIndexes();
      await _createChangeTriggers();
    },
    onUpgrade: (m, from, to) async {
      // Migrations run sequentially: add `if (from < N) { ... }` blocks here.
      if (from < 2) await _migrateToWorkspaces(m);
      if (from < 3) {
        await m.addColumn(collections, collections.authJson);
        await m.addColumn(collections, collections.variablesJson);
      }
      if (from < 4) await _migrateToCloudSync(m);
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
      await _ensureDefaultWorkspace();
    },
  );

  /// v2: existing data moves into the default workspace, together with the
  /// active environment, open tabs and GitHub sync target.
  Future<void> _migrateToWorkspaces(Migrator m) async {
    await m.createTable(workspaces);
    await m.addColumn(collections, collections.workspaceId);
    await m.addColumn(environments, environments.workspaceId);
    await m.addColumn(historyEntries, historyEntries.workspaceId);
    await _createIndexes();
    await _ensureDefaultWorkspace();

    final settings = await customSelect(
      "SELECT value FROM settings_entries WHERE key = 'app_settings'",
    ).getSingleOrNull();
    String? activeEnv;
    try {
      final json = jsonDecode(settings?.read<String>('value') ?? '{}');
      if (json is Map && json['activeEnvironmentId'] is String) {
        activeEnv = json['activeEnvironmentId'] as String;
      }
    } on FormatException {
      // Unreadable settings: start without an active environment.
    }
    if (activeEnv != null) {
      await (update(workspaces)..where((w) => w.id.equals(defaultWorkspaceId)))
          .write(WorkspacesCompanion(activeEnvironmentId: Value(activeEnv)));
    }
    for (final (from, to) in [
      ('workspace', 'workspace.tabs.$defaultWorkspaceId'),
      ('github.sync_target', 'github.sync_target.$defaultWorkspaceId'),
    ]) {
      await customStatement(
        'UPDATE settings_entries SET key = ? WHERE key = ?',
        [to, from],
      );
    }
  }

  /// v4: change tracking for cloud sync, and deterministic Globals ids.
  Future<void> _migrateToCloudSync(Migrator m) async {
    await m.createTable(syncOutbox);
    await m.createTable(syncFlags);
    final globals = await customSelect(
      'SELECT id, workspace_id FROM environments WHERE is_global = 1',
    ).get();
    final rekey = <String, String>{};
    for (final row in globals) {
      final oldId = row.read<String>('id');
      final newId = globalsEnvironmentId(row.read<String>('workspace_id'));
      if (oldId == newId) continue;
      rekey[oldId] = newId;
      // env_variables reference environments(id): copy, repoint, delete.
      await customStatement(
        'INSERT INTO environments (id, workspace_id, name, is_global, sort_order, created_at, updated_at) '
        'SELECT ?, workspace_id, name, is_global, sort_order, created_at, updated_at FROM environments WHERE id = ?',
        [newId, oldId],
      );
      await customStatement(
        'UPDATE env_variables SET environment_id = ? WHERE environment_id = ?',
        [newId, oldId],
      );
      await customStatement('DELETE FROM environments WHERE id = ?', [oldId]);
    }
    if (rekey.isNotEmpty) {
      // Secret values live in the vault under the old ids; moved at startup.
      await customStatement(
        'INSERT OR REPLACE INTO settings_entries (key, value) VALUES (?, ?)',
        [pendingVaultRekeyKey, jsonEncode(rekey)],
      );
    }
    await _createChangeTriggers();
  }

  /// Settings key holding environment ids whose vault secrets must move.
  static const pendingVaultRekeyKey = 'migrate.environment_rekey';

  /// Records every change to a synced table in [syncOutbox]. Rows created
  /// automatically on each device (the default workspace and Globals) are
  /// not recorded on insert, so a fresh device never overwrites cloud data.
  Future<void> _createChangeTriggers() async {
    const silent = 'NOT EXISTS (SELECT 1 FROM sync_flags)';
    const now = "strftime('%Y-%m-%dT%H:%M:%fZ', 'now')";
    final specs = [
      ('workspaces', 'workspace', 'id', "NEW.id <> '$defaultWorkspaceId'"),
      ('collections', 'collection', 'id', null),
      ('folders', 'folder', 'id', null),
      ('requests', 'request', 'id', null),
      ('environments', 'environment', 'id', 'NEW.is_global = 0'),
      ('env_variables', 'environment', 'environment_id', null),
      ('history_entries', 'history', 'id', null),
    ];
    for (final (table, kind, idColumn, insertCondition) in specs) {
      for (final (event, row) in [
        ('INSERT', 'NEW'),
        ('UPDATE', 'NEW'),
        ('DELETE', 'OLD'),
      ]) {
        final condition = event == 'INSERT' && insertCondition != null
            ? '$silent AND $insertCondition'
            : silent;
        await customStatement(
          'CREATE TRIGGER IF NOT EXISTS sync_${table}_${event.toLowerCase()} '
          'AFTER $event ON $table WHEN $condition BEGIN '
          'INSERT INTO sync_outbox (kind, item_id, changed_at) '
          "VALUES ('$kind', $row.$idColumn, $now) "
          'ON CONFLICT (kind, item_id) DO UPDATE SET changed_at = excluded.changed_at; '
          'END',
        );
      }
    }
  }

  /// Runs [action] in a transaction without recording changes for sync.
  Future<T> withoutChangeTracking<T>(Future<T> Function() action) =>
      transaction(() async {
        await into(syncFlags).insert(
          const SyncFlagsCompanion(name: Value('applying')),
          mode: InsertMode.insertOrReplace,
        );
        try {
          return await action();
        } finally {
          await delete(syncFlags).go();
        }
      });

  Future<void> _ensureDefaultWorkspace() async {
    final now = DateTime.now();
    await into(workspaces).insert(
      WorkspacesCompanion.insert(
        id: defaultWorkspaceId,
        name: defaultWorkspaceName,
        createdAt: now,
        updatedAt: now,
      ),
      mode: InsertMode.insertOrIgnore,
    );
  }

  Future<void> _createIndexes() async {
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_requests_collection ON requests (collection_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_folders_collection ON folders (collection_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_history_executed ON history_entries (executed_at)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_env_vars_env ON env_variables (environment_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_collections_workspace ON collections (workspace_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_environments_workspace ON environments (workspace_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_history_workspace ON history_entries (workspace_id)',
    );
  }

  /// Deletes every row in every table (Settings → Clear local database),
  /// leaving an empty default workspace.
  /// Deletes all workspaces, collections, environments and history but keeps
  /// settings. Nothing is recorded for sync.
  Future<void> wipeContent() => withoutChangeTracking(() async {
    for (final TableInfo<Table, Object?> table in [
      historyEntries,
      envVariables,
      environments,
      requests,
      folders,
      collections,
      workspaces,
      syncStates,
      syncOutbox,
    ]) {
      await delete(table).go();
    }
    await _ensureDefaultWorkspace();
  });

  /// Nothing is recorded for sync, so cloud data is left untouched.
  Future<void> wipe() => withoutChangeTracking(() async {
    for (final table in allTables.toList().reversed) {
      if (table == syncFlags) continue;
      await delete(table).go();
    }
    await _ensureDefaultWorkspace();
  });
}
