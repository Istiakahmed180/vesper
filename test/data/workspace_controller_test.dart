import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/core/di/app_providers.dart';
import 'package:vesper/core/security/secret_vault.dart';
import 'package:vesper/core/storage/app_database.dart';
import 'package:vesper/features/api_client/domain/models/api_request.dart';
import 'package:vesper/features/api_client/domain/models/key_value.dart';
import 'package:vesper/features/workspace/domain/workspace_models.dart';
import 'package:vesper/features/workspace/presentation/workspace_controller.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test(
    'opening a request without a params table rebuilds it from the URL',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          vaultProvider.overrideWithValue(InMemoryVault()),
        ],
      );
      addTearDown(container.dispose);
      final repo = container.read(collectionRepositoryProvider);
      final c = await repo.createCollection('API');
      final saved = await repo.saveRequest(
        ApiRequest(
          name: 'No params',
          url: 'https://x.dev/a?restart=1&b=2',
          collectionId: c.id,
        ),
      );

      final ws = container.read(workspaceProvider.notifier);
      await ws.openSavedRequest(saved.id);
      final tab = container.read(workspaceProvider).activeTab! as RequestTab;
      expect(tab.draft.params.map((p) => (p.key, p.value)), [
        ('restart', '1'),
        ('b', '2'),
      ]);
      expect(
        tab.isDirty,
        isFalse,
        reason: 'normalization must not mark the tab dirty',
      );

      // Editing the table keeps the existing query.
      ws.setParams(tab.id, [
        ...tab.draft.params,
        KeyValue(key: 'c', value: '3'),
      ]);
      final edited = container.read(workspaceProvider).activeTab! as RequestTab;
      expect(edited.draft.url, 'https://x.dev/a?restart=1&b=2&c=3');
      await Future<void>.delayed(const Duration(milliseconds: 700));
    },
  );
}
