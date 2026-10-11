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
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await _createIndexes();
    },
    onUpgrade: (m, from, to) async {
      // Migrations run sequentially: add `if (from < N) { ... }` blocks here.
      if (from < 2) await _migrateToWorkspaces(m);
      if (from < 3) {
        await m.addColumn(collections, collections.authJson);
        await m.addColumn(collections, collections.variablesJson);
      }
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
  Future<void> wipe() => transaction(() async {
    for (final table in allTables.toList().reversed) {
      await delete(table).go();
    }
    await _ensureDefaultWorkspace();
  });
}
