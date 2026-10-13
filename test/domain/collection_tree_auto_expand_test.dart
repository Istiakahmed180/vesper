import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/core/di/app_providers.dart';
import 'package:vesper/core/security/secret_vault.dart';
import 'package:vesper/core/storage/app_database.dart';
import 'package:vesper/features/api_client/domain/models/api_request.dart';
import 'package:vesper/features/collections/domain/collection_models.dart';
import 'package:vesper/features/collections/presentation/collection_providers.dart';
import 'package:vesper/features/workspace/presentation/workspace_controller.dart';

void main() {
  group('CollectionTree ancestorIdsForRequest', () {
    test('returns collection and nested folder IDs for a request', () {
      final col = Collection(id: 'c1', name: 'Collection');
      final folder1 = Folder(id: 'f1', collectionId: 'c1', name: 'Folder 1');
      final folder2 = Folder(
        id: 'f2',
        collectionId: 'c1',
        parentId: 'f1',
        name: 'Folder 2',
      );
      final req = ApiRequest(
        id: 'r1',
        name: 'Req',
        collectionId: 'c1',
        folderId: 'f2',
      );

      final tree = CollectionTree.build(col, [folder1, folder2], [req]);

      final ancestors = [tree].ancestorIdsForRequest('r1');
      expect(ancestors, equals({'c1', 'f1', 'f2'}));
    });

    test('returns only collection ID for top-level request', () {
      final col = Collection(id: 'c1', name: 'Collection');
      final req = ApiRequest(id: 'r1', name: 'Req', collectionId: 'c1');

      final tree = CollectionTree.build(col, [], [req]);

      final ancestors = [tree].ancestorIdsForRequest('r1');
      expect(ancestors, equals({'c1'}));
    });

    test('returns empty set if request is not found', () {
      final col = Collection(id: 'c1', name: 'Collection');
      final tree = CollectionTree.build(col, [], []);

      final ancestors = [tree].ancestorIdsForRequest('non_existent');
      expect(ancestors, isEmpty);
    });
  });

  test(
    'selecting/activating a request tab expands its parent folders and collection',
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
      final col = await repo.createCollection('Test Col');
      final folder1 = await repo.createFolder(col.id, 'Folder 1');
      final folder2 = await repo.createFolder(
        col.id,
        'Folder 2',
        parentId: folder1.id,
      );
      final req = await repo.saveRequest(
        ApiRequest(
          name: 'Nested Req',
          collectionId: col.id,
          folderId: folder2.id,
        ),
      );

      final sub = container.listen(
        collectionTreesProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(sub.close);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final ws = container.read(workspaceProvider.notifier);
      await ws.openSavedRequest(req.id);

      final expanded = container.read(expandedNodesProvider);
      expect(expanded, containsAll([col.id, folder1.id, folder2.id]));
    },
  );
}
