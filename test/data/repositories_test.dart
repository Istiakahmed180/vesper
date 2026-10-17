import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/core/errors/app_failure.dart';
import 'package:vesper/core/security/secret_vault.dart';
import 'package:vesper/core/storage/app_database.dart';
import 'package:vesper/features/api_client/domain/models/api_request.dart';
import 'package:vesper/features/api_client/domain/models/http_method.dart';
import 'package:vesper/features/api_client/domain/models/key_value.dart';
import 'package:vesper/features/api_client/domain/models/request_auth.dart';
import 'package:vesper/features/collections/data/drift_collection_repository.dart';
import 'package:vesper/features/collections/domain/collection_models.dart';
import 'package:vesper/features/collections/domain/collection_repository.dart';
import 'package:vesper/features/environments/data/drift_environment_repository.dart';
import 'package:vesper/features/environments/domain/environment_models.dart';
import 'package:vesper/features/history/data/drift_history_repository.dart';
import 'package:vesper/features/history/domain/history_models.dart';
import 'package:vesper/features/settings/data/settings_repository.dart';
import 'package:vesper/features/settings/domain/app_settings.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late AppDatabase db;
  late InMemoryVault vault;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    vault = InMemoryVault();
  });
  tearDown(() => db.close());

  group('CollectionRepository', () {
    late DriftCollectionRepository repo;
    setUp(() => repo = DriftCollectionRepository(db, vault));

    test('creates collections, folders and requests as a tree', () async {
      final c = await repo.createCollection('API');
      final auth = await repo.createFolder(c.id, 'Authentication');
      await repo.saveRequest(
        ApiRequest(name: 'Login', collectionId: c.id, folderId: auth.id),
      );
      await repo.saveRequest(
        ApiRequest(name: 'Register', collectionId: c.id, folderId: auth.id),
      );
      await repo.saveRequest(ApiRequest(name: 'Health', collectionId: c.id));

      final trees = await repo.watchTrees().first;
      expect(trees.single.collection.name, 'API');
      final folder = trees.single.children.first as FolderNode;
      expect(folder.name, 'Authentication');
      expect(folder.children.map((n) => n.name), ['Login', 'Register']);
      expect((trees.single.children.last as RequestNode).name, 'Health');
      expect(trees.single.requestCount, 3);
    });

    test('stores auth secrets in the vault, not in SQLite', () async {
      final c = await repo.createCollection('API');
      final saved = await repo.saveRequest(
        ApiRequest(
          collectionId: c.id,
          auth: const BearerAuth(token: 'top-secret'),
        ),
      );
      final row = await (db.select(db.requests)).getSingle();
      expect(row.authJson, isNot(contains('top-secret')));
      expect(
        await vault.read(VaultKeys.requestAuth(saved.id, 'token')),
        'top-secret',
      );

      final loaded = await repo.getRequest(saved.id);
      expect(loaded!.auth, const BearerAuth(token: 'top-secret'));

      await repo.deleteRequest(saved.id);
      expect(await vault.readAll(), isEmpty);
    });

    test('rename, duplicate and delete cascade', () async {
      final c = await repo.createCollection('API');
      final f = await repo.createFolder(c.id, 'Users');
      final r = await repo.saveRequest(
        ApiRequest(
          name: 'Get Users',
          collectionId: c.id,
          folderId: f.id,
          auth: const BasicAuth(username: 'u', password: 'p'),
        ),
      );
      await repo.renameRequest(r.id, 'List users');
      final dup = await repo.duplicateRequest(r.id);
      expect(dup.name, 'List users copy');
      expect(
        (await repo.getRequest(dup.id))!.auth,
        const BasicAuth(username: 'u', password: 'p'),
      );

      final dupFolderId = await repo.duplicateFolder(f.id);
      var tree = (await repo.watchTrees().first).single;
      expect(tree.allFolders.length, 2);
      expect(tree.requestCount, 4);

      await repo.deleteFolder(dupFolderId);
      tree = (await repo.watchTrees().first).single;
      expect(tree.requestCount, 2);

      await repo.deleteCollection(c.id);
      expect(await repo.watchTrees().first, isEmpty);
      expect(await db.select(db.requests).get(), isEmpty);
      expect(await vault.readAll(), isEmpty);
    });

    test('moves and reorders requests and folders', () async {
      final c = await repo.createCollection('API');
      final f1 = await repo.createFolder(c.id, 'A');
      final f2 = await repo.createFolder(c.id, 'B');
      final r1 = await repo.saveRequest(
        ApiRequest(name: 'one', collectionId: c.id),
      );
      final r2 = await repo.saveRequest(
        ApiRequest(name: 'two', collectionId: c.id),
      );
      await repo.moveRequest(r2.id, TreeLocation(c.id), index: 0);
      var tree = (await repo.watchTrees().first).single;
      expect(tree.children.whereType<RequestNode>().map((n) => n.name), [
        'two',
        'one',
      ]);

      await repo.moveRequest(r1.id, TreeLocation(c.id, f1.id));
      await repo.moveFolder(f2.id, TreeLocation(c.id, f1.id));
      tree = (await repo.watchTrees().first).single;
      final a = tree.children.whereType<FolderNode>().single;
      expect(a.children.map((n) => n.name), ['B', 'one']);

      expect(
        () => repo.moveFolder(f1.id, TreeLocation(c.id, f2.id)),
        throwsA(anything),
      );

      final other = await repo.createCollection('Other');
      await repo.moveFolder(f1.id, TreeLocation(other.id));
      final trees = await repo.watchTrees().first;
      expect(
        trees.firstWhere((t) => t.collection.id == other.id).requestCount,
        1,
      );
    });

    test('export and import round trip', () async {
      final c = await repo.createCollection('API', description: 'desc');
      final f = await repo.createFolder(c.id, 'Users');
      await repo.saveRequest(
        ApiRequest(
          name: 'Me',
          method: HttpMethod.post,
          url: '{{base_url}}/me',
          headers: [KeyValue(key: 'X', value: '1')],
          collectionId: c.id,
          folderId: f.id,
          auth: const BearerAuth(token: 'secret'),
        ),
      );
      final withoutSecrets = await repo.exportCollection(c.id);
      final req =
          ((withoutSecrets.items.single as FolderItem).items.single
                  as RequestItem)
              .request;
      expect(req.auth, const BearerAuth());

      final withSecrets = await repo.exportCollection(
        c.id,
        includeSecrets: true,
      );
      final newId = await repo.importCollection(withSecrets);
      final imported = (await repo.watchTrees().first).firstWhere(
        (t) => t.collection.id == newId,
      );
      final importedReq = imported.allRequests.single;
      expect(importedReq.url, '{{base_url}}/me');
      expect(
        (await repo.getRequest(importedReq.id))!.auth,
        const BearerAuth(token: 'secret'),
      );
    });

    test('exports a single folder with the collection settings', () async {
      final c = await repo.createCollection('Chat API');
      await repo.saveSettings(
        c.id,
        const CollectionSettings(auth: BearerAuth(token: '{{token}}')),
      );
      final conversations = await repo.createFolder(c.id, 'Conversations');
      final threads = await repo.createFolder(
        c.id,
        'Threads',
        parentId: conversations.id,
      );
      final users = await repo.createFolder(c.id, 'Users');
      await repo.saveRequest(
        ApiRequest(
          name: 'List',
          collectionId: c.id,
          folderId: conversations.id,
          auth: const InheritAuth(),
        ),
      );
      await repo.saveRequest(
        ApiRequest(name: 'Messages', collectionId: c.id, folderId: threads.id),
      );
      await repo.saveRequest(
        ApiRequest(name: 'Profile', collectionId: c.id, folderId: users.id),
      );

      final doc = await repo.exportFolder(conversations.id);
      expect(doc.name, 'Conversations');
      expect(doc.items, hasLength(2));
      expect((doc.items[0] as FolderItem).name, 'Threads');
      expect(
        ((doc.items[0] as FolderItem).items.single as RequestItem).request.name,
        'Messages',
      );
      expect((doc.items[1] as RequestItem).request.name, 'List');
      // Secrets are left out unless asked for.
      expect(doc.settings.auth, const BearerAuth());
      final full = await repo.exportFolder(
        conversations.id,
        includeSecrets: true,
      );
      expect(full.settings.auth, const BearerAuth(token: '{{token}}'));

      // Importing it gives a collection with just that folder's requests.
      final id = await repo.importCollection(doc);
      final tree = (await repo.watchTrees().first).firstWhere(
        (t) => t.collection.id == id,
      );
      expect(tree.allRequests.map((r) => r.name).toSet(), {'Messages', 'List'});

      await expectLater(
        repo.exportFolder('missing'),
        throwsA(isA<StorageFailure>()),
      );
    });

    test('exports a single request with the collection settings', () async {
      final c = await repo.createCollection('API');
      await repo.saveSettings(
        c.id,
        const CollectionSettings(auth: BearerAuth(token: '{{token}}')),
      );
      final req = await repo.saveRequest(
        ApiRequest(
          name: 'Me',
          url: '{{base_url}}/me',
          collectionId: c.id,
          auth: const BearerAuth(token: 'secret'),
        ),
      );
      await repo.saveRequest(ApiRequest(name: 'Other', collectionId: c.id));

      final doc = await repo.exportRequest(req.id);
      expect(doc.name, 'Me');
      final exported = (doc.items.single as RequestItem).request;
      expect(exported.url, '{{base_url}}/me');
      // Secrets are left out unless asked for.
      expect(exported.auth, const BearerAuth());
      expect(doc.settings.auth, const BearerAuth());
      final full = await repo.exportRequest(req.id, includeSecrets: true);
      expect(
        (full.items.single as RequestItem).request.auth,
        const BearerAuth(token: 'secret'),
      );
      expect(full.settings.auth, const BearerAuth(token: '{{token}}'));

      await expectLater(
        repo.exportRequest('missing'),
        throwsA(isA<StorageFailure>()),
      );
    });

    test('imports into a folder', () async {
      final c = await repo.createCollection('API');
      final users = await repo.createFolder(c.id, 'Users');
      await repo.saveRequest(
        ApiRequest(name: 'List', collectionId: c.id, folderId: users.id),
      );
      await repo.importIntoCollection(
        c.id,
        CollectionDocument(
          name: 'Profile',
          items: [RequestItem(ApiRequest(name: 'Profile'))],
        ),
        folderId: users.id,
      );
      final tree = (await repo.watchTrees().first).firstWhere(
        (t) => t.collection.id == c.id,
      );
      final folder = tree.children.whereType<FolderNode>().single;
      expect(
        folder.children.whereType<RequestNode>().map((n) => n.request.name),
        ['List', 'Profile'],
      );
    });

    test('replaceRequest overwrites content and keeps its place', () async {
      final c = await repo.createCollection('API');
      final users = await repo.createFolder(c.id, 'Users');
      final original = await repo.saveRequest(
        ApiRequest(
          name: 'Old',
          url: 'https://old.test',
          collectionId: c.id,
          folderId: users.id,
          auth: const BearerAuth(token: 'old-secret'),
        ),
      );

      final saved = await repo.replaceRequest(
        original.id,
        ApiRequest(
          name: 'New',
          method: HttpMethod.post,
          url: 'https://new.test',
        ),
      );
      expect(saved.id, original.id);
      final reloaded = (await repo.getRequest(original.id))!;
      expect(reloaded.name, 'New');
      expect(reloaded.method, HttpMethod.post);
      expect(reloaded.url, 'https://new.test');
      expect(reloaded.collectionId, c.id);
      expect(reloaded.folderId, users.id);
      expect(reloaded.sortOrder, original.sortOrder);
      // The old secret does not linger in the vault.
      expect(reloaded.auth, isNot(const BearerAuth(token: 'old-secret')));

      await expectLater(
        repo.replaceRequest('missing', ApiRequest(name: 'X')),
        throwsA(isA<StorageFailure>()),
      );
    });

    test('replaceCollection swaps contents', () async {
      final c = await repo.createCollection('API');
      await repo.saveRequest(ApiRequest(name: 'old', collectionId: c.id));
      await repo.replaceCollection(
        c.id,
        CollectionDocument(
          name: 'API v2',
          items: [RequestItem(ApiRequest(name: 'new'))],
        ),
      );
      final tree = (await repo.watchTrees().first).single;
      expect(tree.collection.name, 'API v2');
      expect(tree.allRequests.map((r) => r.name), ['new']);
    });
  });

  group('EnvironmentRepository', () {
    late DriftEnvironmentRepository repo;
    setUp(() => repo = DriftEnvironmentRepository(db, vault));

    test('creates globals automatically and stores secrets in vault', () async {
      final initial = await repo.watchEnvironments().first;
      expect(initial.single.isGlobal, isTrue);

      final dev = await repo.createEnvironment('Development');
      await repo.saveEnvironment(
        dev.copyWith(
          variables: [
            EnvVariable(key: 'base_url', value: 'https://dev.example.com'),
            EnvVariable(key: 'token', value: 'abc123', isSecret: true),
          ],
        ),
      );
      final rows = await db.select(db.envVariables).get();
      expect(rows.map((r) => r.value), isNot(contains('abc123')));

      final envs = await repo.watchEnvironments().first;
      final loaded = envs.firstWhere((e) => e.name == 'Development');
      expect(loaded.variables.map((v) => v.value), [
        'https://dev.example.com',
        'abc123',
      ]);

      final copy = await repo.duplicateEnvironment(dev.id);
      final copyLoaded = (await repo.watchEnvironments().first).firstWhere(
        (e) => e.id == copy.id,
      );
      expect(copyLoaded.variables.last.value, 'abc123');

      await repo.deleteEnvironment(dev.id);
      final keys = (await vault.readAll()).keys;
      expect(keys.where((k) => k.contains(dev.id)), isEmpty);
    });

    test('watch streams stay independent of other repositories', () async {
      final collections = DriftCollectionRepository(db, vault);
      final collectionNames = <int>[];
      final envNames = <List<String>>[];
      final s1 = collections.watchTrees().listen(
        (t) => collectionNames.add(t.length),
      );
      final s2 = repo.watchEnvironments().listen(
        (e) => envNames.add([for (final x in e) x.name]),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await repo.createEnvironment('Dev');
      await collections.createCollection('API');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await s1.cancel();
      await s2.cancel();
      expect(envNames.last, ['Globals', 'Dev']);
      expect(collectionNames.last, 1);
    });

    test('globals cannot be deleted', () async {
      final globals = (await repo.watchEnvironments().first).single;
      expect(() => repo.deleteEnvironment(globals.id), throwsA(anything));
    });
  });

  group('HistoryRepository', () {
    late DriftHistoryRepository repo;
    setUp(() => repo = DriftHistoryRepository(db));

    test('records sanitized entries', () async {
      await repo.add(
        HistoryEntry(
          request: ApiRequest(
            url: 'https://user:pw@x.dev/a?api_key=literal&q=1',
            params: [
              KeyValue(key: 'api_key', value: 'literal'),
              KeyValue(key: 'q', value: '1'),
            ],
            headers: [
              KeyValue(key: 'Authorization', value: 'Bearer literal-token'),
              KeyValue(key: 'X-Token', value: '{{token}}'),
            ],
            auth: const BearerAuth(token: 'literal-token'),
          ),
          statusCode: 200,
          duration: const Duration(milliseconds: 120),
        ),
      );
      final row = await db.select(db.historyEntries).getSingle();
      expect(row.requestJson, isNot(contains('literal')));
      expect(row.url, isNot(contains('pw')));
      final entry = (await repo.watch().first).single;
      expect(entry.request.headers.last.value, '{{token}}');
      expect(entry.statusCode, 200);
    });

    test('prunes by count and age', () async {
      for (var i = 0; i < 15; i++) {
        await repo.add(
          HistoryEntry(
            request: ApiRequest(url: 'https://x.dev/$i'),
            executedAt: DateTime.now().subtract(Duration(days: i)),
          ),
        );
      }
      await repo.prune(retentionDays: 10, maxEntries: 5);
      final left = await repo.watch().first;
      expect(left.length, 5);
      expect(left.first.url, 'https://x.dev/0');
      await repo.clear();
      expect(await repo.watch().first, isEmpty);
    });
  });

  group('SettingsRepository', () {
    test('round trips settings', () async {
      final repo = SettingsRepository(db);
      expect((await repo.loadSettings()).network.timeoutMs, 30000);
      await repo.saveSettings(
        const AppSettings(
          network: NetworkSettings(timeoutMs: 5000, verifySsl: false),
          historyRetentionDays: 7,
        ),
      );
      final loaded = await repo.loadSettings();
      expect(loaded.network.timeoutMs, 5000);
      expect(loaded.network.verifySsl, isFalse);
      expect(loaded.historyRetentionDays, 7);
    });
  });
}
