import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/core/errors/app_failure.dart';
import 'package:vesper/core/security/secret_vault.dart';
import 'package:vesper/core/storage/app_database.dart';
import 'package:vesper/features/api_client/domain/models/api_request.dart';
import 'package:vesper/features/api_client/domain/models/request_auth.dart';
import 'package:vesper/features/collections/data/drift_collection_repository.dart';
import 'package:vesper/features/sync/data/sync_data.dart';
import 'package:vesper/features/sync/domain/sync_models.dart';
import 'package:vesper/features/sync/domain/sync_service.dart';

/// In-memory remote with GitHub-like sha preconditions.
class FakeRemote implements RemoteFileStore {
  final files = <String, RemoteFileData>{};
  int _rev = 0;

  @override
  String get remoteKey => 'fake:repo@main';

  @override
  Future<RemoteFileData?> read(String path) async => files[path];

  @override
  Future<List<String>> listFiles(String directory) async =>
      files.keys.where((p) => p.startsWith('$directory/')).toList();

  @override
  Future<String> write(
    String path,
    String content, {
    required String message,
    String? expectedSha,
  }) async {
    final current = files[path];
    if (current != null && current.sha != expectedSha) {
      throw const SyncFailure('conflict');
    }
    if (current == null && expectedSha != null) {
      throw const SyncFailure('conflict');
    }
    final sha = 'sha${++_rev}';
    files[path] = RemoteFileData(path: path, sha: sha, content: content);
    return sha;
  }

  /// Simulates a commit made by someone else.
  void externalEdit(String path, String content) => files[path] =
      RemoteFileData(path: path, sha: 'ext${++_rev}', content: content);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late AppDatabase db;
  late DriftCollectionRepository repo;
  late SyncService sync;
  late FakeRemote remote;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = DriftCollectionRepository(db, InMemoryVault());
    sync = SyncService(collections: repo, states: DriftSyncStateStore(db));
    remote = FakeRemote();
  });
  tearDown(() => db.close());

  Future<SyncItem> item(String id) async {
    final plan = await sync.plan(remote, await repo.watchTrees().first);
    return plan.items.firstWhere((i) => i.collectionId == id);
  }

  test('push new collection, then up to date, never leaks secrets', () async {
    final c = await repo.createCollection('Users API');
    await repo.saveRequest(
      ApiRequest(
        name: 'Me',
        collectionId: c.id,
        auth: const BearerAuth(token: 'TOPSECRET'),
      ),
    );
    var i = await item(c.id);
    expect(i.status, SyncStatus.newLocal);
    expect(i.path, 'api-client/collections/users-api.json');
    await sync.push(remote, i);
    expect(remote.files.values.single.content, isNot(contains('TOPSECRET')));
    i = await item(c.id);
    expect(i.status, SyncStatus.unchanged);
  });

  test('detects local, remote and conflicting changes', () async {
    final c = await repo.createCollection('API');
    final r = await repo.saveRequest(
      ApiRequest(name: 'One', collectionId: c.id),
    );
    await sync.push(remote, await item(c.id));

    await repo.renameRequest(r.id, 'One renamed');
    expect((await item(c.id)).status, SyncStatus.localChanged);
    await sync.push(remote, await item(c.id));
    expect((await item(c.id)).status, SyncStatus.unchanged);

    // Remote edit: take the current file and change a request name.
    final path = (await item(c.id)).path;
    remote.externalEdit(
      path,
      remote.files[path]!.content.replaceAll('One renamed', 'Remote name'),
    );
    var i = await item(c.id);
    expect(i.status, SyncStatus.remoteChanged);
    await sync.pull(remote, i);
    final tree = (await repo.watchTrees().first).single;
    expect(tree.allRequests.single.name, 'Remote name');
    expect((await item(c.id)).status, SyncStatus.unchanged);

    // Both sides change → conflict, which requires an explicit overwrite.
    remote.externalEdit(
      path,
      remote.files[path]!.content.replaceAll('Remote name', 'Theirs'),
    );
    await repo.renameRequest(tree.allRequests.single.id, 'Mine');
    i = await item(c.id);
    expect(i.status, SyncStatus.conflict);
    expect(() => sync.push(remote, i), throwsA(isA<SyncFailure>()));
    await sync.push(remote, i, overwrite: true);
    expect(remote.files[path]!.content, contains('Mine'));
  });

  test('stale sha is rejected by the remote', () async {
    final c = await repo.createCollection('API');
    await sync.push(remote, await item(c.id));
    await repo.updateCollection(c.id, description: 'changed');
    final stale = await item(c.id);
    remote.externalEdit(stale.path, remote.files[stale.path]!.content);
    expect(() => sync.push(remote, stale), throwsA(isA<SyncFailure>()));
  });

  test('imports collections that only exist remotely', () async {
    final c = await repo.createCollection('Shared');
    await repo.saveRequest(ApiRequest(name: 'Ping', collectionId: c.id));
    await sync.push(remote, await item(c.id));
    await repo.deleteCollection(c.id);

    final plan = await sync.plan(remote, await repo.watchTrees().first);
    final remoteOnly = plan.items.single;
    expect(remoteOnly.status, SyncStatus.remoteOnly);
    final id = await sync.pull(remote, remoteOnly);
    final tree = (await repo.watchTrees().first).single;
    expect(tree.collection.id, id);
    expect(tree.allRequests.single.name, 'Ping');
    expect((await item(id)).status, SyncStatus.unchanged);
  });

  test(
    'a stale tree list with a deleted collection does not break the plan',
    () async {
      final c = await repo.createCollection('Gone soon');
      await sync.push(remote, await item(c.id));
      final stale = await repo.watchTrees().first;
      await repo.deleteCollection(c.id);
      final plan = await sync.plan(remote, stale);
      expect(plan.items.single.status, SyncStatus.remoteOnly);
    },
  );

  test(
    'an unsynced namesake does not take over a deleted collection file',
    () async {
      final original = await repo.createCollection('Shared Name');
      final first = await item(original.id);
      await sync.push(remote, first);
      final copy = await repo.createCollection('Shared Name');
      await repo.deleteCollection(original.id);

      final plan = await sync.plan(remote, await repo.watchTrees().first);
      final local = plan.items.singleWhere((i) => i.collectionId == copy.id);
      expect(local.status, SyncStatus.newLocal);
      expect(local.path, isNot(first.path));
      final orphan = plan.items.singleWhere((i) => i.path == first.path);
      expect(orphan.status, SyncStatus.remoteOnly);
    },
  );
}
