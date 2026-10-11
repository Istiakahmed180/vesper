import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/core/security/secret_vault.dart';
import 'package:vesper/core/storage/app_database.dart';
import 'package:vesper/features/api_client/domain/models/api_request.dart';
import 'package:vesper/features/api_client/domain/models/request_auth.dart';
import 'package:vesper/features/api_client/domain/services/request_preparer.dart';
import 'package:vesper/features/api_client/domain/services/variable_resolver.dart';
import 'package:vesper/features/collections/data/drift_collection_repository.dart';
import 'package:vesper/features/collections/domain/collection_models.dart';
import 'package:vesper/features/collections/domain/collection_repository.dart';
import 'package:vesper/features/collections/presentation/collection_providers.dart';
import 'package:vesper/features/environments/domain/environment_models.dart';
import 'package:vesper/features/import_export/domain/collection_codec.dart';
import 'package:vesper/features/import_export/domain/import_service.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late AppDatabase db;
  late InMemoryVault vault;
  late DriftCollectionRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    vault = InMemoryVault();
    repo = DriftCollectionRepository(db, vault);
  });
  tearDown(() => db.close());

  final settings = CollectionSettings(
    auth: const BearerAuth(token: 'collection-token'),
    variables: [
      EnvVariable(key: 'base_url', value: 'https://api.dev'),
      EnvVariable(key: 'api_key', value: 'k-123', isSecret: true),
    ],
  );

  group('collection settings storage', () {
    test('secrets go to the vault, the rest to SQLite', () async {
      final c = await repo.createCollection('API');
      await repo.saveSettings(c.id, settings);

      final row = await db.select(db.collections).getSingle();
      expect(row.authJson, isNot(contains('collection-token')));
      expect(row.variablesJson, isNot(contains('k-123')));
      expect(row.variablesJson, contains('https://api.dev'));
      expect(await repo.getSettings(c.id), settings);

      await repo.deleteCollection(c.id);
      final keys = (await vault.readAll()).keys;
      expect(keys.where((k) => k.contains(c.id)), isEmpty);
    });

    test('removing a secret also removes it from the vault', () async {
      final c = await repo.createCollection('API');
      await repo.saveSettings(c.id, settings);
      await repo.saveSettings(c.id, const CollectionSettings());
      expect(await vault.readAll(), isEmpty);
      expect(await repo.getSettings(c.id), const CollectionSettings());
    });

    test('export strips secrets unless asked; import restores', () async {
      final c = await repo.createCollection('API');
      await repo.saveSettings(c.id, settings);

      final plain = await repo.exportCollection(c.id);
      expect(plain.settings.auth, const BearerAuth());
      expect(plain.settings.variables.last.value, isEmpty);

      final full = await repo.exportCollection(c.id, includeSecrets: true);
      final copyId = await repo.importCollection(full);
      final copy = (await repo.getSettings(copyId))!;
      expect(copy.auth, settings.auth);
      expect(copy.variables.map((v) => (v.key, v.value, v.isSecret)), [
        ('base_url', 'https://api.dev', false),
        ('api_key', 'k-123', true),
      ]);
    });

    test('a sync pull keeps local secrets the file does not carry', () async {
      final c = await repo.createCollection('API');
      await repo.saveSettings(c.id, settings);
      final pulled = await repo.exportCollection(c.id); // no secrets
      await repo.replaceCollection(
        c.id,
        CollectionDocument(
          name: 'API v2',
          settings: pulled.settings.copyWith(
            variables: [
              ...pulled.settings.variables,
              EnvVariable(key: 'new_var', value: 'x'),
            ],
          ),
        ),
      );
      final after = (await repo.getSettings(c.id))!;
      expect(after.auth, settings.auth);
      expect(
        after.variables.firstWhere((v) => v.key == 'api_key').value,
        'k-123',
      );
      expect(after.variables.map((v) => v.key), contains('new_var'));
    });

    test('the Vesper format round-trips collection settings', () {
      const codec = VesperCollectionCodec();
      final doc = CollectionDocument(name: 'API', settings: settings);
      final withoutSecrets = codec.parse(codec.encode(doc)).value.settings;
      expect(withoutSecrets.auth, const BearerAuth());
      expect(withoutSecrets.variables.first.value, 'https://api.dev');
      final withSecrets = codec
          .parse(codec.encode(doc, includeSecrets: true))
          .value
          .settings;
      expect(withSecrets.auth, settings.auth);
      expect(withSecrets.variables.last.value, 'k-123');
    });
  });

  group('sending with collection settings', () {
    final env = VariableResolver(
      environment: {
        'base_url': const VariableValue(
          'https://env.dev',
          VariableSource.environment,
        ),
      },
      globals: {
        'tenant': const VariableValue('g', VariableSource.global),
        'api_key': const VariableValue('global-key', VariableSource.global),
      },
    );

    test('environment > collection > globals', () async {
      final context = await loadRequestContext(
        (_) async => settings,
        env,
        'c1',
      );
      final r = context.resolver;
      expect(r('{{base_url}}'), 'https://env.dev', reason: 'env wins');
      expect(r('{{api_key}}'), 'k-123', reason: 'collection beats globals');
      expect(r('{{tenant}}'), 'g');
      expect(r.lookup('api_key')!.source, VariableSource.collection);
    });

    test('inheriting requests send the collection auth', () async {
      final context = await loadRequestContext(
        (_) async => settings,
        env,
        'c1',
      );
      final prepared = const RequestPreparer().prepare(
        ApiRequest(url: 'https://x.dev', auth: const InheritAuth()),
        context.resolver,
        inheritedAuth: context.inheritedAuth,
      );
      expect(
        prepared.headers,
        contains(
          isA<MapEntry<String, String>>()
              .having((h) => h.key, 'key', 'Authorization')
              .having((h) => h.value, 'value', 'Bearer collection-token'),
        ),
      );

      // Own auth wins; no collection means nothing is inherited.
      final own = const RequestPreparer().prepare(
        ApiRequest(url: 'https://x.dev', auth: const NoAuth()),
        context.resolver,
        inheritedAuth: context.inheritedAuth,
      );
      expect(own.hasHeader('Authorization'), isFalse);
      final unsaved = await loadRequestContext(
        (_) async => settings,
        env,
        null,
      );
      expect(unsaved.inheritedAuth, isNull);
      expect(
        const RequestPreparer()
            .prepare(
              ApiRequest(url: 'https://x.dev', auth: const InheritAuth()),
              unsaved.resolver,
            )
            .hasHeader('Authorization'),
        isFalse,
      );
    });
  });

  test('Postman collection auth, folder auth and variables are imported', () {
    final result = const ImportService().parseCollection({
      'info': {
        'name': 'Shop',
        'schema':
            'https://schema.getpostman.com/json/collection/v2.1.0/collection.json',
      },
      'auth': {
        'type': 'bearer',
        'bearer': [
          {'key': 'token', 'value': '{{token}}'},
        ],
      },
      'variable': [
        {'key': 'host', 'value': 'https://shop.dev'},
        {'key': 'secret', 'value': 's', 'type': 'secret'},
      ],
      'item': [
        {
          'name': 'Inherits',
          'request': {'method': 'GET', 'url': '{{host}}/a'},
        },
        {
          'name': 'Public',
          'request': {
            'method': 'GET',
            'url': '{{host}}/b',
            'auth': {'type': 'noauth'},
          },
        },
        {
          'name': 'Admin',
          'auth': {
            'type': 'basic',
            'basic': [
              {'key': 'username', 'value': 'admin'},
              {'key': 'password', 'value': 'pw'},
            ],
          },
          'item': [
            {
              'name': 'Stats',
              'request': {'method': 'GET', 'url': '{{host}}/stats'},
            },
          ],
        },
      ],
    });
    final doc = result.value;
    expect(doc.settings.auth, const BearerAuth(token: '{{token}}'));
    expect(doc.settings.variables.map((v) => (v.key, v.isSecret)), [
      ('host', false),
      ('secret', true),
    ]);
    expect((doc.items[0] as RequestItem).request.auth, const InheritAuth());
    expect((doc.items[1] as RequestItem).request.auth, const NoAuth());
    final stats =
        ((doc.items[2] as FolderItem).items.single as RequestItem).request;
    expect(stats.auth, const BasicAuth(username: 'admin', password: 'pw'));
    expect(
      result.warnings.where((w) => w.contains('Collection')),
      isEmpty,
      reason: 'collection auth and variables are no longer dropped',
    );
  });

  test('a new collection has no auth or variables', () async {
    final c = await repo.createCollection('API');
    expect(await repo.getSettings(c.id), const CollectionSettings());
    expect(await repo.getSettings('missing'), isNull);
  });
}
