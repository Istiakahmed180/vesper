import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/core/security/secret_vault.dart';
import 'package:vesper/core/storage/app_database.dart';
import 'package:vesper/features/api_client/domain/models/api_request.dart';
import 'package:vesper/features/api_client/domain/models/saved_response.dart';
import 'package:vesper/features/collections/data/drift_collection_repository.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late AppDatabase db;
  late DriftCollectionRepository repo;
  late String collectionId;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = DriftCollectionRepository(db, InMemoryVault());
    collectionId = (await repo.createCollection('API')).id;
  });
  tearDown(() => db.close());

  final ok = SavedResponse(
    name: 'Success',
    statusCode: 200,
    statusMessage: 'OK',
    headers: const [MapEntry('content-type', 'application/json')],
    body: '{"status":true}',
  );
  final bad = SavedResponse(
    name: 'Invalid amount',
    statusCode: 422,
    body: '{"status":false}',
  );

  test('new requests start without examples', () async {
    final saved = await repo.saveRequest(
      ApiRequest(name: 'Top Up', collectionId: collectionId),
    );
    expect((await repo.getRequest(saved.id))!.examples, isEmpty);
  });

  test('saveRequest persists examples', () async {
    final saved = await repo.saveRequest(
      ApiRequest(
        name: 'Top Up',
        collectionId: collectionId,
        examples: [ok, bad],
      ),
    );
    final loaded = (await repo.getRequest(saved.id))!;
    expect(loaded.examples.map((e) => e.name), ['Success', 'Invalid amount']);
    expect(loaded.examples.first.headers.single.value, 'application/json');
    expect(loaded.examples.last.statusCode, 422);
  });

  test('saveExamples replaces examples and leaves the request intact', () async {
    final saved = await repo.saveRequest(
      ApiRequest(
        name: 'Top Up',
        url: 'https://api.test/topup',
        collectionId: collectionId,
      ),
    );
    await repo.saveExamples(saved.id, [ok]);
    var loaded = (await repo.getRequest(saved.id))!;
    expect(loaded.examples.single.name, 'Success');
    expect(loaded.name, 'Top Up');
    expect(loaded.url, 'https://api.test/topup');

    await repo.saveExamples(saved.id, [bad]);
    loaded = (await repo.getRequest(saved.id))!;
    expect(loaded.examples.single.name, 'Invalid amount');

    await repo.saveExamples(saved.id, const []);
    expect((await repo.getRequest(saved.id))!.examples, isEmpty);
  });

  test('duplicated requests keep their examples', () async {
    final saved = await repo.saveRequest(
      ApiRequest(name: 'Top Up', collectionId: collectionId, examples: [ok]),
    );
    final copy = await repo.duplicateRequest(saved.id);
    expect((await repo.getRequest(copy.id))!.examples.single.name, 'Success');
  });

  test('requests table has the examples column at schema 6', () async {
    final columns = await db
        .customSelect("PRAGMA table_info('requests')")
        .get();
    expect(
      columns.map((c) => c.read<String>('name')),
      contains('examples_json'),
    );
    expect(db.schemaVersion, 6);
  });
}
