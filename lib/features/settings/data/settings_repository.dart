import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/storage/app_database.dart';
import '../../../core/utils/json_read.dart';
import '../domain/app_settings.dart';

/// Key/value settings persisted in SQLite.
class SettingsRepository {
  SettingsRepository(this._db);

  final AppDatabase _db;

  static const appSettingsKey = 'app_settings';
  static const workspaceKey = 'workspace';

  Future<String?> read(String key) async {
    final row = await (_db.select(
      _db.settingsEntries,
    )..where((s) => s.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> write(String key, String value) => _db
      .into(_db.settingsEntries)
      .insertOnConflictUpdate(
        SettingsEntriesCompanion(key: Value(key), value: Value(value)),
      );

  Future<void> remove(String key) =>
      (_db.delete(_db.settingsEntries)..where((s) => s.key.equals(key))).go();

  Future<JsonMap?> readJson(String key) async {
    final raw = await read(key);
    if (raw == null) return null;
    try {
      final v = jsonDecode(raw);
      return v is Map ? v.cast<String, Object?>() : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> writeJson(String key, JsonMap value) =>
      write(key, jsonEncode(value));

  Future<AppSettings> loadSettings() async {
    final json = await readJson(appSettingsKey);
    return json == null ? const AppSettings() : AppSettings.fromJson(json);
  }

  Future<void> saveSettings(AppSettings settings) =>
      writeJson(appSettingsKey, settings.toJson());
}
