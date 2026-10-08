import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../constants/app_constants.dart';

part 'app_database.g.dart';

@DataClassName('CollectionRow')
class Collections extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get description => text().withDefault(const Constant(''))();
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
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await _createIndexes();
    },
    onUpgrade: (m, from, to) async {
      // Migrations run sequentially: add `if (from < N) { ... }` blocks here.
      // Example for a future v2:
      //   if (from < 2) await m.addColumn(requests, requests.someNewColumn);
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

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
  }

  /// Deletes every row in every table (Settings → Clear local database).
  Future<void> wipe() => transaction(() async {
    for (final table in allTables.toList().reversed) {
      await delete(table).go();
    }
  });
}
