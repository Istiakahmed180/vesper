import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/core/di/app_providers.dart';
import 'package:vesper/core/errors/app_failure.dart';
import 'package:vesper/core/logging/app_logger.dart';
import 'package:vesper/core/security/secret_vault.dart';
import 'package:vesper/core/storage/app_database.dart';
import 'package:vesper/features/api_client/domain/models/api_request.dart';
import 'package:vesper/features/api_client/domain/models/request_auth.dart';
import 'package:vesper/features/collections/data/drift_collection_repository.dart';
import 'package:vesper/features/collections/presentation/collection_providers.dart';
import 'package:vesper/features/environments/data/drift_environment_repository.dart';
import 'package:vesper/features/environments/domain/environment_models.dart';
import 'package:vesper/features/environments/presentation/environment_providers.dart';
import 'package:vesper/features/github/data/github_api.dart';
import 'package:vesper/features/github/domain/github_models.dart';
import 'package:vesper/features/history/data/drift_history_repository.dart';
import 'package:vesper/features/history/domain/history_models.dart';
import 'package:vesper/features/settings/data/settings_repository.dart';
import 'package:vesper/features/sync/data/sync_data.dart';
import 'package:vesper/features/workspace/domain/workspace_models.dart';
import 'package:vesper/features/workspace/presentation/workspace_controller.dart';
import 'package:vesper/features/workspaces/data/workspace_repository.dart';
import 'package:vesper/features/workspaces/presentation/workspace_providers.dart';

/// Schema v1 (before workspaces), as created by the first released build.
const _v1Schema = [
  'CREATE TABLE collections (id TEXT NOT NULL PRIMARY KEY, name TEXT NOT NULL, '
      "description TEXT NOT NULL DEFAULT '', sort_order INTEGER NOT NULL DEFAULT 0, "
      'created_at TEXT NOT NULL, updated_at TEXT NOT NULL)',
  'CREATE TABLE folders (id TEXT NOT NULL PRIMARY KEY, collection_id TEXT NOT NULL '
      'REFERENCES collections (id) ON DELETE CASCADE, parent_id TEXT NULL '
      'REFERENCES folders (id) ON DELETE CASCADE, name TEXT NOT NULL, '
      'sort_order INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL, '
      'updated_at TEXT NOT NULL)',
  'CREATE TABLE requests (id TEXT NOT NULL PRIMARY KEY, collection_id TEXT NOT NULL '
      'REFERENCES collections (id) ON DELETE CASCADE, folder_id TEXT NULL '
      'REFERENCES folders (id) ON DELETE CASCADE, name TEXT NOT NULL, '
      "method TEXT NOT NULL, url TEXT NOT NULL, params_json TEXT NOT NULL DEFAULT '[]', "
      "headers_json TEXT NOT NULL DEFAULT '[]', body_json TEXT NOT NULL DEFAULT '{}', "
      "auth_json TEXT NOT NULL DEFAULT '{}', options_json TEXT NOT NULL DEFAULT '{}', "
      "description TEXT NOT NULL DEFAULT '', sort_order INTEGER NOT NULL DEFAULT 0, "
      'created_at TEXT NOT NULL, updated_at TEXT NOT NULL)',
  'CREATE TABLE environments (id TEXT NOT NULL PRIMARY KEY, name TEXT NOT NULL, '
      'is_global INTEGER NOT NULL DEFAULT 0, sort_order INTEGER NOT NULL DEFAULT 0, '
      'created_at TEXT NOT NULL, updated_at TEXT NOT NULL)',
  'CREATE TABLE env_variables (id TEXT NOT NULL PRIMARY KEY, environment_id TEXT NOT NULL '
      'REFERENCES environments (id) ON DELETE CASCADE, key TEXT NOT NULL, '
      "value TEXT NOT NULL DEFAULT '', enabled INTEGER NOT NULL DEFAULT 1, "
      'is_secret INTEGER NOT NULL DEFAULT 0, sort_order INTEGER NOT NULL DEFAULT 0)',
  'CREATE TABLE history_entries (id TEXT NOT NULL PRIMARY KEY, request_id TEXT NULL, '
      'method TEXT NOT NULL, url TEXT NOT NULL, status_code INTEGER NULL, '
      'error_message TEXT NULL, duration_ms INTEGER NOT NULL DEFAULT 0, '
      'size_bytes INTEGER NOT NULL DEFAULT 0, executed_at TEXT NOT NULL, '
      'request_json TEXT NOT NULL)',
  'CREATE TABLE settings_entries (key TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL)',
  'CREATE TABLE sync_states (item_key TEXT NOT NULL, remote TEXT NOT NULL, '
      'path TEXT NOT NULL, remote_sha TEXT NOT NULL, content_hash TEXT NOT NULL, '
      'synced_at TEXT NOT NULL, PRIMARY KEY (item_key, remote))',
];

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late AppDatabase db;
  late InMemoryVault vault;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    vault = InMemoryVault();
  });
  tearDown(() => db.close());

  test('a default workspace always exists, also after wipe', () async {
    final repo = WorkspaceRepository(db, vault);
    expect((await repo.watchAll().first).single.name, defaultWorkspaceName);
    await repo.create('Client A');
    await db.wipe();
    final all = await repo.watchAll().first;
    expect(all.single.id, defaultWorkspaceId);
  });

  test(
    'collections, environments and history stay in their workspace',
    () async {
      final other = await WorkspaceRepository(db, vault).create('Client A');
      final colsA = DriftCollectionRepository(db, vault);
      final colsB = DriftCollectionRepository(db, vault, workspaceId: other.id);
      await colsA.createCollection('Mine');
      await colsB.createCollection('Theirs');
      expect((await colsA.watchTrees().first).map((t) => t.collection.name), [
        'Mine',
      ]);
      expect((await colsB.watchTrees().first).map((t) => t.collection.name), [
        'Theirs',
      ]);

      final envA = DriftEnvironmentRepository(db, vault);
      final envB = DriftEnvironmentRepository(db, vault, workspaceId: other.id);
      await envA.createEnvironment('Local');
      final listA = await envA.watchEnvironments().first;
      final listB = await envB.watchEnvironments().first;
      expect(listA.map((e) => e.name), ['Globals', 'Local']);
      expect(listB.map((e) => e.name), ['Globals'], reason: 'own Globals');
      expect(listA.first.id, isNot(listB.first.id));

      final histA = DriftHistoryRepository(db);
      final histB = DriftHistoryRepository(db, workspaceId: other.id);
      await histB.add(HistoryEntry(request: ApiRequest(url: 'https://b.dev')));
      expect(await histA.watch().first, isEmpty);
      expect((await histB.watch().first).single.request.url, 'https://b.dev');
      await histA.clear();
      expect(
        await histB.watch().first,
        hasLength(1),
        reason: 'clear is scoped',
      );
    },
  );

  test('deleting a workspace removes its data and secrets only', () async {
    final repo = WorkspaceRepository(db, vault);
    final other = await repo.create('Client A');
    final cols = DriftCollectionRepository(db, vault, workspaceId: other.id);
    final c = await cols.createCollection('Theirs');
    final r = await cols.saveRequest(
      ApiRequest(
        collectionId: c.id,
        auth: const BearerAuth(token: 'secret'),
      ),
    );
    final envs = DriftEnvironmentRepository(db, vault, workspaceId: other.id);
    final env = await envs.createEnvironment(
      'Prod',
      variables: [EnvVariable(key: 'token', value: 'abc', isSecret: true)],
    );
    final mine = DriftEnvironmentRepository(db, vault);
    final keep = await mine.createEnvironment(
      'Keep',
      variables: [EnvVariable(key: 'token', value: 'keep', isSecret: true)],
    );
    await SettingsRepository(
      db,
    ).writeJson(SettingsRepository.tabsKey(other.id), {'tabs': <Object>[]});

    await expectLater(
      repo.delete(defaultWorkspaceId),
      throwsA(isA<ValidationFailure>()),
    );
    await repo.delete(other.id);

    expect(await repo.get(other.id), isNull);
    expect(await db.select(db.collections).get(), isEmpty);
    expect(await db.select(db.requests).get(), isEmpty);
    final vaultKeys = (await vault.readAll()).keys;
    expect(vaultKeys.where((k) => k.contains(r.id)), isEmpty);
    expect(vaultKeys.where((k) => k.contains(env.id)), isEmpty);
    expect(vaultKeys.where((k) => k.contains(keep.id)), isNotEmpty);
    expect(
      await SettingsRepository(db).read(SettingsRepository.tabsKey(other.id)),
      isNull,
    );
    expect((await mine.watchEnvironments().first).map((e) => e.name), [
      'Globals',
      'Keep',
    ]);
  });

  test('a collection can move to another workspace', () async {
    final other = await WorkspaceRepository(db, vault).create('Client A');
    final mine = DriftCollectionRepository(db, vault);
    final theirs = DriftCollectionRepository(db, vault, workspaceId: other.id);
    await theirs.createCollection('Existing');
    final c = await mine.createCollection('Move me');
    await mine.saveRequest(ApiRequest(name: 'Ping', collectionId: c.id));

    await mine.moveCollectionToWorkspace(c.id, other.id);

    expect(await mine.watchTrees().first, isEmpty);
    final trees = await theirs.watchTrees().first;
    expect(trees.map((t) => t.collection.name), ['Existing', 'Move me']);
    expect(trees.last.requestCount, 1);
  });

  test('upgrading a v1 database keeps all data in the default workspace', () async {
    final legacy = AppDatabase(
      NativeDatabase.memory(
        setup: (raw) {
          for (final sql in _v1Schema) {
            raw.execute(sql);
          }
          const now = '2026-01-01T00:00:00.000';
          raw
            ..execute(
              "INSERT INTO collections (id, name, created_at, updated_at) VALUES ('c1', 'Old API', '$now', '$now')",
            )
            ..execute(
              "INSERT INTO environments (id, name, is_global, created_at, updated_at) VALUES ('g', 'Globals', 1, '$now', '$now'), ('e1', 'Sandbox', 0, '$now', '$now')",
            )
            ..execute(
              "INSERT INTO settings_entries (key, value) VALUES ('app_settings', '{\"activeEnvironmentId\":\"e1\",\"themeMode\":\"light\"}'), ('workspace', '{\"tabs\":[]}'), ('github.sync_target', '{\"repo\":\"me/api\"}')",
            )
            ..execute('PRAGMA user_version = 1');
        },
      ),
    );
    addTearDown(legacy.close);

    final workspace = await WorkspaceRepository(
      legacy,
      vault,
    ).get(defaultWorkspaceId);
    expect(workspace!.activeEnvironmentId, 'e1');
    final trees = await DriftCollectionRepository(
      legacy,
      vault,
    ).watchTrees().first;
    expect(trees.single.collection.name, 'Old API');
    final envs = await DriftEnvironmentRepository(
      legacy,
      vault,
    ).watchEnvironments().first;
    expect(envs.map((e) => e.name), ['Globals', 'Sandbox']);
    expect(envs.first.id, globalsEnvironmentId(defaultWorkspaceId));
    final settings = SettingsRepository(legacy);
    expect(
      await settings.read(AppDatabase.pendingVaultRekeyKey),
      contains('globals-default'),
      reason: 'secret Globals values move in the vault at startup',
    );
    expect(await settings.read('workspace'), isNull);
    expect(
      await settings.read(SettingsRepository.tabsKey(defaultWorkspaceId)),
      isNotNull,
    );
    expect(
      await settings.readJson(
        SettingsRepository.syncTargetKey(defaultWorkspaceId),
      ),
      {'repo': 'me/api'},
    );
  });

  test('sync records are kept apart per workspace', () {
    const target = SyncTarget(repo: 'me/api', branch: 'main');
    GitHubFileStore store(String workspaceId) => GitHubFileStore(
      api: GitHubApi(logger: AppLogger()),
      token: 't',
      target: target,
      workspaceId: workspaceId,
    );
    expect(store(defaultWorkspaceId).remoteKey, target.remoteKey);
    expect(store('w2').remoteKey, isNot(target.remoteKey));
    expect(store('w2').remoteKey, isNot(store('w3').remoteKey));
  });

  group('switching workspaces', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          vaultProvider.overrideWithValue(vault),
        ],
      );
      // Keep the stream providers alive like the UI does.
      container
        ..listen(collectionTreesProvider, (_, _) {})
        ..listen(environmentsProvider, (_, _) {})
        ..listen(workspacesProvider, (_, _) {})
        // The tab controller exists from startup in the app.
        ..listen(workspaceProvider, (_, _) {});
    });
    tearDown(() => container.dispose());

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 50));

    test(
      'rescopes data, keeps each workspace\'s tabs and environment',
      () async {
        final active = container.read(activeWorkspaceIdProvider.notifier);
        final tabs = container.read(workspaceProvider.notifier);
        final c = await container
            .read(collectionRepositoryProvider)
            .createCollection('Mine');
        final saved = await container
            .read(collectionRepositoryProvider)
            .saveRequest(ApiRequest(name: 'Saved', collectionId: c.id));
        final env = await container
            .read(environmentRepositoryProvider)
            .createEnvironment('Local');
        await active.setActiveEnvironment(env.id);
        await tabs.openSavedRequest(saved.id);
        final draftTab = tabs.newRequestTab(
          ApiRequest(name: 'Draft', url: 'https://draft.dev'),
        );
        await settle();
        expect(container.read(activeEnvironmentProvider)?.name, 'Local');

        final other = await active.create('Client A');
        await settle();
        expect(container.read(activeWorkspaceIdProvider), other.id);
        expect(container.read(collectionTreesProvider).value, isEmpty);
        expect(container.read(activeEnvironmentProvider), isNull);
        final otherTabs = container.read(workspaceProvider).tabs;
        expect(otherTabs, hasLength(1));
        expect(otherTabs.single.isDirty, isFalse);

        await active.select(defaultWorkspaceId);
        await settle();
        final back = container.read(workspaceProvider);
        expect(back.tabs.map((t) => t.title), ['Saved', 'Draft']);
        expect(back.activeTabId, draftTab, reason: 'unsaved draft kept');
        final savedTab = back.tabs.first as RequestTab;
        expect(
          savedTab.isSaved,
          isTrue,
          reason: 'still linked after switching',
        );
        expect(container.read(activeEnvironmentProvider)?.name, 'Local');
        expect(
          container
              .read(collectionTreesProvider)
              .value!
              .map((t) => t.collection.name),
          ['Mine'],
        );
      },
    );

    test('restores saved tabs of a workspace from disk', () async {
      final other = await WorkspaceRepository(db, vault).create('Client A');
      final repo = DriftCollectionRepository(db, vault, workspaceId: other.id);
      final c = await repo.createCollection('Theirs');
      final r = await repo.saveRequest(
        ApiRequest(name: 'Remembered', collectionId: c.id),
      );
      await SettingsRepository(db).writeJson(
        SettingsRepository.tabsKey(other.id),
        {
          'tabs': [
            {'requestId': r.id},
          ],
          'active': r.id,
        },
      );

      await container.read(activeWorkspaceIdProvider.notifier).select(other.id);
      await settle();
      final tab = container.read(workspaceProvider).activeTab! as RequestTab;
      expect(tab.title, 'Remembered');
      expect(tab.isSaved, isTrue);
      expect(
        await SettingsRepository(
          db,
        ).read(SettingsRepository.activeWorkspaceKey),
        other.id,
      );
    });
  });
}
