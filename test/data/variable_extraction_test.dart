import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/core/di/app_providers.dart';
import 'package:vesper/core/security/secret_vault.dart';
import 'package:vesper/core/storage/app_database.dart';
import 'package:vesper/features/api_client/domain/models/api_request.dart';
import 'package:vesper/features/api_client/domain/models/api_response.dart';
import 'package:vesper/features/api_client/domain/models/http_method.dart';
import 'package:vesper/features/api_client/domain/models/variable_extraction.dart';
import 'package:vesper/features/api_client/domain/services/response_extractor.dart';
import 'package:vesper/features/environments/domain/environment_models.dart';
import 'package:vesper/features/environments/presentation/environment_providers.dart';
import 'package:vesper/features/workspace/presentation/variable_updater.dart';
import 'package:vesper/features/workspaces/presentation/workspace_providers.dart';

ApiResponse jsonResponse(Object body, {int status = 200}) => ApiResponse(
  statusCode: status,
  statusMessage: 'OK',
  headers: const [
    MapEntry('content-type', 'application/json'),
    MapEntry('x-request-id', 'req-1'),
  ],
  bodyBytes: Uint8List.fromList(utf8.encode(jsonEncode(body))),
  duration: Duration.zero,
  requestUrl: 'https://api.dev/login',
  method: HttpMethod.post,
);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('paths', () {
    final json = {
      'token': 'abc',
      'data': {
        'access_token': 'xyz',
        'items': [
          {'id': 7},
          {'id': 8},
        ],
        'weird key': true,
      },
    };
    test('dot, index, root and bracket paths', () {
      expect(ResponseExtractor.readPath(json, 'token'), 'abc');
      expect(ResponseExtractor.readPath(json, r'$.data.access_token'), 'xyz');
      expect(ResponseExtractor.readPath(json, 'data.items[1].id'), 8);
      expect(ResponseExtractor.readPath(json, 'data.items.0.id'), 7);
      expect(ResponseExtractor.readPath(json, "data['weird key']"), true);
      expect(ResponseExtractor.readPath(json, 'data.missing'), isNull);
      expect(ResponseExtractor.readPath(json, 'data.items[5]'), isNull);
    });

    test('rules read the body or a header; objects become JSON', () {
      final results = const ResponseExtractor().extract(jsonResponse(json), [
        VariableExtraction(variable: 'token', path: 'token'),
        VariableExtraction(variable: 'items', path: 'data.items'),
        VariableExtraction(
          variable: 'rid',
          source: ExtractionSource.header,
          path: 'X-Request-ID',
        ),
        VariableExtraction(variable: 'nope', path: 'missing'),
        VariableExtraction(variable: 'off', path: 'token', enabled: false),
      ]);
      expect(results.map((r) => r.value), [
        'abc',
        '[{"id":7},{"id":8}]',
        'req-1',
        null,
      ]);
      expect(results.last.error, contains('not found'));
    });
  });

  group('saving', () {
    late AppDatabase db;
    late ProviderContainer container;
    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          vaultProvider.overrideWithValue(InMemoryVault()),
        ],
      );
      container
        ..listen(environmentsProvider, (_, _) {})
        ..listen(workspacesProvider, (_, _) {});
    });
    tearDown(() async {
      container.dispose();
      await db.close();
    });

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 50));

    final login = ApiRequest(
      method: HttpMethod.post,
      url: '{{base_url}}/login',
      options: RequestOptions(
        extractions: [
          VariableExtraction(variable: 'token', path: 'token'),
          VariableExtraction(
            variable: 'last_login',
            path: 'meta.at',
            target: ExtractionTarget.globals,
          ),
        ],
      ),
    );

    test('a successful login updates the active environment', () async {
      final env = await container
          .read(environmentRepositoryProvider)
          .createEnvironment(
            'Sandbox',
            variables: [
              EnvVariable(key: 'base_url', value: 'https://api.dev'),
              EnvVariable(key: 'token', value: 'old'),
            ],
          );
      await container
          .read(activeWorkspaceIdProvider.notifier)
          .setActiveEnvironment(env.id);
      await settle();

      final provider = Provider((ref) => ref);
      final ref = container.read(provider);
      final notes = await applyExtractions(
        ref,
        login,
        jsonResponse({
          'token': 'new-token',
          'meta': {'at': '2026-10-12'},
        }),
      );
      await settle();
      expect(notes.every((n) => n.ok), isTrue, reason: '$notes');
      final sandbox = container.read(activeEnvironmentProvider)!;
      expect(sandbox.variables.map((v) => (v.key, v.value)), [
        ('base_url', 'https://api.dev'),
        ('token', 'new-token'),
      ], reason: 'existing variable updated in place');
      final globals = container.read(globalsEnvironmentProvider)!;
      expect(globals.variables.single.value, '2026-10-12');
    });

    test('failed responses and missing environments change nothing', () async {
      final provider = Provider((ref) => ref);
      final ref = container.read(provider);
      final failed = await applyExtractions(
        ref,
        login,
        jsonResponse({'token': 'x'}, status: 401),
      );
      expect(failed.single.ok, isFalse);

      final noEnv = await applyExtractions(
        ref,
        login,
        jsonResponse({
          'token': 'x',
          'meta': {'at': 'now'},
        }),
      );
      expect(
        noEnv.firstWhere((n) => !n.ok).message,
        contains('select an environment'),
      );
    });
  });
}
