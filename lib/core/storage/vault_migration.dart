import 'dart:convert';

import '../security/secret_vault.dart';
import 'app_database.dart';

/// Moves secret environment values to the environment ids assigned by a
/// database migration (see [AppDatabase.pendingVaultRekeyKey]). Runs once at
/// startup; the database migration cannot reach the vault itself.
Future<void> migrateEnvironmentVaultKeys(
  AppDatabase db,
  SecretVault vault,
) async {
  final row =
      await (db.select(db.settingsEntries)
            ..where((s) => s.key.equals(AppDatabase.pendingVaultRekeyKey)))
          .getSingleOrNull();
  if (row == null) return;
  Object? decoded;
  try {
    decoded = jsonDecode(row.value);
  } on FormatException {
    // Unreadable: drop the marker below.
  }
  if (decoded is Map) {
    final all = await vault.readAll();
    for (final MapEntry(:key, :value) in decoded.entries) {
      if (key is! String || value is! String) continue;
      final from = VaultKeys.environmentPrefix(key);
      final to = VaultKeys.environmentPrefix(value);
      for (final entry in all.entries.where((e) => e.key.startsWith(from))) {
        await vault.write(
          '$to${entry.key.substring(from.length)}',
          entry.value,
        );
        await vault.delete(entry.key);
      }
    }
  }
  await (db.delete(
    db.settingsEntries,
  )..where((s) => s.key.equals(AppDatabase.pendingVaultRekeyKey))).go();
}
