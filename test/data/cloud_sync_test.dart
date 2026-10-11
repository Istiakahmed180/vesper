import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/core/security/secret_vault.dart';
import 'package:vesper/core/storage/app_database.dart';
import 'package:vesper/core/storage/vault_migration.dart';
import 'package:vesper/features/api_client/domain/models/api_request.dart';
import 'package:vesper/features/api_client/domain/models/request_auth.dart';
import 'package:vesper/features/cloud_sync/data/drift_local_sync_store.dart';
import 'package:vesper/features/cloud_sync/domain/cloud_models.dart';
import 'package:vesper/features/cloud_sync/domain/sync_engine.dart';
import 'package:vesper/features/collections/data/drift_collection_repository.dart';
import 'package:vesper/features/collections/domain/collection_models.dart';
import 'package:vesper/features/environments/data/drift_environment_repository.dart';
import 'package:vesper/features/environments/domain/environment_models.dart';
import 'package:vesper/features/workspaces/data/workspace_repository.dart';

/// In-memory cloud with the same rules as the Supabase tables: newest
/// client time wins and every write gets a later server time. Personal
/// spaces are per user; shared workspaces are visible to their members.
class FakeCloud {
  /// Space (`user:<id>` or a shared workspace id) → item key → item.
  final spaces = <String, Map<String, CloudItem>>{};
  final members = <String, Map<String, WorkspaceRole>>{};
  var _clock = DateTime.utc(2026);

  Iterable<CloudItem> get items => spaces.values.expand((s) => s.values);

  void store(String space, CloudItem item) {
    final items = spaces.putIfAbsent(space, () => {});
    final existing = items[item.key];
    if (existing != null &&
        item.clientUpdatedAt.isBefore(existing.clientUpdatedAt)) {
      return;
    }
    _clock = _clock.add(const Duration(seconds: 1));
    items[item.key] = CloudItem(
      kind: item.kind,
      id: item.id,
      data: item.data,
      clientUpdatedAt: item.clientUpdatedAt,
      serverUpdatedAt: _clock,
      scope: item.scope,
    );
  }
}

class FakeCloudView implements CloudStore {
  FakeCloudView(this.cloud, this.userId);
  final FakeCloud cloud;
  final String userId;

  String _space(String? scope) {
    if (scope == null) return 'user:$userId';
    if (cloud.members[scope]?.containsKey(userId) != true) {
      throw StateError('$userId is not a member of $scope');
    }
    return scope;
  }

  @override
  Future<void> upsert(List<CloudItem> batch) async {
    for (final item in batch) {
      cloud.store(_space(item.scope), item);
    }
  }

  @override
  Future<List<CloudItem>> changesSince(
    DateTime? cursor, {
    String? scope,
  }) async => [
    for (final i in (cloud.spaces[_space(scope)] ?? const {}).values)
      if (cursor == null || i.serverUpdatedAt!.isAfter(cursor)) i,
  ]..sort((a, b) => a.serverUpdatedAt!.compareTo(b.serverUpdatedAt!));

  @override
  Future<Map<String, WorkspaceRole>> memberships() async => {
    for (final MapEntry(:key, :value) in cloud.members.entries)
      key: ?value[userId],
  };
}

class Device {
  Device(this.cloud, {this.userId = 'me'})
    : db = AppDatabase(NativeDatabase.memory()),
      vault = InMemoryVault();

  final FakeCloud cloud;
  final String userId;
  final AppDatabase db;
  final InMemoryVault vault;

  late final store = DriftLocalSyncStore(db, vault);
  late final engine = SyncEngine(
    local: store,
    cloud: FakeCloudView(cloud, userId),
  );
  DriftCollectionRepository collections([String ws = defaultWorkspaceId]) =>
      DriftCollectionRepository(db, vault, workspaceId: ws);
  DriftEnvironmentRepository environments([String ws = defaultWorkspaceId]) =>
      DriftEnvironmentRepository(db, vault, workspaceId: ws);
  WorkspaceRepository get workspaces => WorkspaceRepository(db, vault);

  Future<List<String>> collectionNames([
    String ws = defaultWorkspaceId,
  ]) async => [
    for (final t in await collections(ws).watchTrees().first) t.collection.name,
  ];
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late FakeCloud cloud;
  late Device a;
  late Device b;

  setUp(() {
    cloud = FakeCloud();
    a = Device(cloud);
    b = Device(cloud);
  });
  tearDown(() async {
    await a.db.close();
    await b.db.close();
  });

  test('edits on one device reach the other, secrets stay behind', () async {
    final c = await a.collections().createCollection('Shop API');
    final folder = await a.collections().createFolder(c.id, 'Orders');
    await a.collections().saveRequest(
      ApiRequest(
        name: 'List',
        url: 'https://shop.dev/orders',
        collectionId: c.id,
        folderId: folder.id,
        auth: const BearerAuth(token: 'secret-token'),
      ),
    );
    await a.collections().saveSettings(
      c.id,
      CollectionSettings(
        auth: const BearerAuth(token: 'collection-secret'),
        variables: [EnvVariable(key: 'host', value: 'https://shop.dev')],
      ),
    );
    final env = await a.environments().createEnvironment(
      'Prod',
      variables: [
        EnvVariable(key: 'base', value: 'https://prod.dev'),
        EnvVariable(key: 'key', value: 'k-1', isSecret: true),
      ],
    );
    await a.engine.sync();

    final json = cloud.items.map((i) => '${i.data}').join();
    expect(json, isNot(contains('secret-token')));
    expect(json, isNot(contains('collection-secret')));
    expect(json, isNot(contains('k-1')));

    await b.engine.sync();
    final tree = (await b.collections().watchTrees().first).single;
    expect(tree.collection.name, 'Shop API');
    final request = tree.allRequests.single;
    expect(request.name, 'List');
    expect(request.folderId, folder.id);
    final settings = (await b.collections().getSettings(c.id))!;
    expect(settings.variables.single.value, 'https://shop.dev');
    expect(settings.auth, const BearerAuth(), reason: 'no secret on B');
    final envs = await b.environments().watchEnvironments().first;
    final prod = envs.firstWhere((e) => e.id == env.id);
    expect(prod.variables.map((v) => (v.key, v.value)), [
      ('base', 'https://prod.dev'),
      ('key', ''),
    ]);
    expect(await b.vault.readAll(), isEmpty);
  });

  test('renames, deletes and workspaces sync both ways', () async {
    final ws = await a.workspaces.create('Client A');
    final c = await a.collections(ws.id).createCollection('First');
    await a.engine.sync();
    await b.engine.sync();
    expect((await b.workspaces.get(ws.id))!.name, 'Client A');
    expect(await b.collectionNames(ws.id), ['First']);

    await b.collections(ws.id).updateCollection(c.id, name: 'Renamed on B');
    await b.workspaces.rename(defaultWorkspaceId, 'Personal');
    await b.engine.sync();
    await a.engine.sync();
    expect(await a.collectionNames(ws.id), ['Renamed on B']);
    expect((await a.workspaces.get(defaultWorkspaceId))!.name, 'Personal');

    await a.workspaces.delete(ws.id);
    await a.engine.sync();
    await b.engine.sync();
    expect(await b.workspaces.get(ws.id), isNull);
    expect(await b.db.select(b.db.collections).get(), isEmpty);
  });

  test('a fresh device adopts cloud data instead of overwriting it', () async {
    await a.workspaces.rename(defaultWorkspaceId, 'Personal');
    final globals = await a.environments().watchEnvironments().first;
    await a.environments().saveEnvironment(
      globals.first.copyWith(
        variables: [EnvVariable(key: 'g', value: '1')],
      ),
    );
    await a.engine.sync();

    // B already created its own default workspace and Globals.
    await b.environments().watchEnvironments().first;
    await b.store.enqueueAll();
    await b.engine.sync();
    expect((await b.workspaces.get(defaultWorkspaceId))!.name, 'Personal');
    final bGlobals = (await b.environments().watchEnvironments().first).first;
    expect(bGlobals.isGlobal, isTrue);
    expect(bGlobals.variables.single.key, 'g');
    final allGlobals = await (b.db.select(
      b.db.environments,
    )..where((e) => e.isGlobal.equals(true))).get();
    expect(allGlobals, hasLength(1), reason: 'one Globals per workspace');
  });

  test('the later edit wins a conflict', () async {
    final c = await a.collections().createCollection('Original');
    await a.engine.sync();
    await b.engine.sync();

    await a.collections().updateCollection(c.id, name: 'From A');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await b.collections().updateCollection(c.id, name: 'From B (later)');
    await a.engine.sync();
    await b.engine.sync(); // B's newer change survives its pull, then uploads
    await a.engine.sync();
    expect(await a.collectionNames(), ['From B (later)']);
    expect(await b.collectionNames(), ['From B (later)']);
  });

  test('existing local data is uploaded on the first sync', () async {
    await a.collections().createCollection('Made before sign-in');
    await a.db.delete(a.db.syncOutbox).go(); // as if made before v4
    await a.store.enqueueAll();
    await a.engine.sync();
    await b.engine.sync();
    expect(await b.collectionNames(), ['Made before sign-in']);
  });

  test('applying cloud changes is not echoed back as local changes', () async {
    await a.collections().createCollection('Once');
    await a.engine.sync();
    await b.engine.sync();
    expect(await b.store.pending(), isEmpty);
  });

  test('wiping the local database does not delete cloud data', () async {
    await a.collections().createCollection('Keep in cloud');
    await a.engine.sync();
    await a.db.wipe();
    expect(await a.store.pending(), isEmpty);
    await a.engine.push();
    expect(cloud.items.where((i) => i.deleted), isEmpty);
  });

  test('a deletion from another device also removes local secrets', () async {
    final c = await a.collections().createCollection('API');
    final r = await a.collections().saveRequest(
      ApiRequest(
        collectionId: c.id,
        auth: const BearerAuth(token: 'tok'),
      ),
    );
    await a.engine.sync();
    await b.engine.sync();
    await b.collections().deleteRequest(r.id);
    await b.engine.sync();
    await a.engine.sync();
    expect((await a.collections().watchTrees().first).single.requestCount, 0);
    expect(
      (await a.vault.readAll()).keys.where((k) => k.contains(r.id)),
      isEmpty,
    );
  });

  test('moved Globals ids take their vault secrets along', () async {
    await a.vault.write(VaultKeys.envVariable('old-id', 'v1'), 's3cret');
    await a.db
        .into(a.db.settingsEntries)
        .insert(
          SettingsEntriesCompanion.insert(
            key: AppDatabase.pendingVaultRekeyKey,
            value: '{"old-id": "globals-default"}',
          ),
        );
    await migrateEnvironmentVaultKeys(a.db, a.vault);
    expect(
      await a.vault.read(VaultKeys.envVariable('globals-default', 'v1')),
      's3cret',
    );
    expect(await a.vault.read(VaultKeys.envVariable('old-id', 'v1')), isNull);
    expect(
      await (a.db.select(
        a.db.settingsEntries,
      )..where((s) => s.key.equals(AppDatabase.pendingVaultRekeyKey))).get(),
      isEmpty,
    );
  });

  test('signing out clears the computer; signing in brings everything back '
      'with its secrets', () async {
    final c = await a.collections().createCollection('Account data');
    final r = await a.collections().saveRequest(
      ApiRequest(
        collectionId: c.id,
        auth: const BearerAuth(token: 'kept'),
      ),
    );
    await a.engine.sync();
    expect(await a.store.hasContent(), isTrue);

    // What sign-out does.
    await a.db.wipeContent();
    await a.store.reset();
    expect(await a.store.hasContent(), isFalse);
    expect(await a.collectionNames(), isEmpty);

    // Signing in again: a full pull.
    await a.engine.sync();
    expect(await a.collectionNames(), ['Account data']);
    final restored = await a.collections().getRequest(r.id);
    expect(restored!.auth, const BearerAuth(token: 'kept'));
    expect(cloud.items.where((i) => i.deleted), isEmpty);
  });

  group('shared workspaces', () {
    late Device teammate;
    setUp(() => teammate = Device(cloud, userId: 'teammate'));
    tearDown(() => teammate.db.close());

    Future<String> shareTeamWorkspace() async {
      final ws = await a.workspaces.create('Team API');
      final c = await a.collections(ws.id).createCollection('Orders');
      await a
          .collections(ws.id)
          .saveRequest(
            ApiRequest(
              name: 'List orders',
              collectionId: c.id,
              auth: const BearerAuth(token: 'owner-token'),
            ),
          );
      await a.engine.sync(); // personal first
      cloud.members[ws.id] = {'me': WorkspaceRole.owner};
      await a.store.enqueueWorkspace(ws.id);
      await a.engine.sync();
      return ws.id;
    }

    test('a shared workspace moves out of the personal space', () async {
      final ws = await shareTeamWorkspace();
      final personal = cloud.spaces['user:me']!.values;
      expect(
        personal.where((i) => i.kind == CloudKind.collection && !i.deleted),
        isEmpty,
        reason: 'only a deletion stays in the personal space',
      );
      expect(
        cloud.spaces[ws]!.values.map((i) => i.kind),
        containsAll([
          CloudKind.workspace,
          CloudKind.collection,
          CloudKind.request,
        ]),
      );
      // The owner's other device keeps the collection (and its token).
      final second = Device(cloud);
      addTearDown(second.db.close);
      await second.engine.sync();
      expect(await second.collectionNames(ws), ['Orders']);
    });

    test(
      'members see, edit and leave the workspace; secrets stay private',
      () async {
        final ws = await shareTeamWorkspace();
        cloud.members[ws]!['teammate'] = WorkspaceRole.member;
        await teammate.engine.sync();

        expect((await teammate.workspaces.get(ws))!.name, 'Team API');
        final tree = (await teammate.collections(ws).watchTrees().first).single;
        expect(tree.collection.name, 'Orders');
        final request = await teammate
            .collections(ws)
            .getRequest(tree.allRequests.single.id);
        expect(request!.auth, const BearerAuth(), reason: 'no owner token');

        // The teammate renames; the owner receives it.
        await teammate
            .collections(ws)
            .updateCollection(tree.collection.id, name: 'Orders v2');
        await teammate.engine.sync();
        await a.engine.sync();
        expect(await a.collectionNames(ws), ['Orders v2']);
        // Nothing leaked into the teammate's personal space.
        expect(cloud.spaces['user:teammate'], isNull);

        // Removed from the team: the workspace disappears from their computer.
        cloud.members[ws]!.remove('teammate');
        await teammate.engine.sync();
        expect(await teammate.workspaces.get(ws), isNull);
        expect(
          await teammate.db.select(teammate.db.collections).get(),
          isEmpty,
        );
      },
    );

    test('a collection moved into a shared workspace follows it', () async {
      final ws = await shareTeamWorkspace();
      final mine = await a.collections().createCollection('Was personal');
      final folder = await a.collections().createFolder(mine.id, 'Inside');
      await a.collections().saveRequest(
        ApiRequest(name: 'Nested', collectionId: mine.id, folderId: folder.id),
      );
      await a.engine.sync();
      await a.collections().moveCollectionToWorkspace(mine.id, ws);
      await a.engine.sync();
      cloud.members[ws]!['teammate'] = WorkspaceRole.member;
      await teammate.engine.sync();
      final moved = (await teammate.collections(ws).watchTrees().first)
          .firstWhere((t) => t.collection.name == 'Was personal');
      expect(moved.requestCount, 1, reason: 'contents moved along');
      expect(await a.collectionNames(), isEmpty);
    });
  });
}
