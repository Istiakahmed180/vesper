// Restart / persistence verification. Built once and launched several times
// as separate processes (same binary, so Keychain access stays consistent):
//
//   flutter build macos --profile -t integration_test/macos_persistence.dart --dart-define=VESPER_E2E=1
//   <copy>/Vesper.app/Contents/MacOS/Vesper   # phase 1: write
//   <copy>/Vesper.app/Contents/MacOS/Vesper   # phase 2: verify, drop secrets
//   open build/macos/Build/Products/Release/Vesper.app   # real release binary
//   <copy>/Vesper.app/Contents/MacOS/Vesper   # phase 3: verify again, clean up
//
// The phase is kept in a marker file in the temp directory.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:vesper/bootstrap.dart';
import 'package:vesper/core/di/app_providers.dart';
import 'package:vesper/core/security/secret_vault.dart';
import 'package:vesper/features/api_client/domain/models/api_request.dart';
import 'package:vesper/features/api_client/domain/models/key_value.dart';
import 'package:vesper/features/api_client/domain/models/request_auth.dart';
import 'package:vesper/features/environments/domain/environment_models.dart';
import 'package:vesper/features/environments/presentation/environment_providers.dart';
import 'package:vesper/features/settings/presentation/settings_controller.dart';
import 'package:vesper/features/workspace/domain/workspace_models.dart';
import 'package:vesper/features/workspace/presentation/workspace_controller.dart';

import '../test/support/test_server.dart';
import 'support/harness.dart';

const secret = 'VSPR-RESTART-SECRET-4410';

/// Uses (and wipes) the real app data directory and Keychain: opt-in only.
const enabled =
    String.fromEnvironment('VESPER_E2E') == '1' ||
    String.fromEnvironment('VESPER_E2E') == 'true';
final phaseFile = File(
  p.join(Directory.systemTemp.path, 'vesper_persistence_phase'),
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Uses (and wipes) the real app data directory and Keychain: opt-in only.
  testWidgets(skip: !enabled, 'persistence across real app restarts', (
    tester,
  ) async {
    final phase = phaseFile.existsSync()
        ? phaseFile.readAsStringSync().trim()
        : 'write';
    // ignore: avoid_print
    print('PHASE START $phase');
    try {
      if (phase == 'write') {
        final dir = await Harness.supportDir();
        for (final n in [
          'vesper.sqlite',
          'vesper.sqlite-wal',
          'vesper.sqlite-shm',
        ]) {
          final f = File(p.join(dir.path, n));
          if (f.existsSync()) f.deleteSync();
        }
      }
      final container = await bootstrap(installErrorHandlers: false);
      await tester.pumpWidget(Harness.wrap(container));
      final h = Harness(tester, container);
      await h.pumpFor(const Duration(milliseconds: 800));
      switch (phase) {
        case 'write':
          await _write(h, container);
          phaseFile.writeAsStringSync('verify');
        case 'verify':
          await _verify(h, container, secretsExpected: true);
          await _dropSecrets(container);
          phaseFile.writeAsStringSync('cleanup');
        case 'cleanup':
          await _verify(h, container, secretsExpected: false);
          await container.read(databaseProvider).wipe();
          await container.read(vaultProvider).clear();
          phaseFile.deleteSync();
          Harness.record(
            'Cleanup',
            detail: 'database wiped, Keychain items removed',
          );
      }
      // ignore: avoid_print
      print('PHASE COMPLETE $phase');
    } catch (e, st) {
      // ignore: avoid_print
      print('PHASE FAILED $phase: $e\n$st');
      rethrow;
    }
  });
}

Future<void> _write(Harness h, ProviderContainer c) async {
  final server = await TestServer.start(port: 8080);
  final repo = c.read(collectionRepositoryProvider);
  final col = await repo.createCollection('Restart Check');
  final folder = await repo.createFolder(col.id, 'Folder A');
  final saved = await repo.saveRequest(
    ApiRequest(
      name: 'Saved GET',
      url: '{{base_url}}/echo?restart=1',
      headers: [KeyValue(key: 'X-Restart', value: 'yes')],
      collectionId: col.id,
      folderId: folder.id,
    ),
  );
  await repo.saveRequest(
    ApiRequest(
      name: 'Secret POST',
      url: '{{base_url}}/echo',
      auth: const BearerAuth(token: secret),
      collectionId: col.id,
    ),
  );
  final envRepo = c.read(environmentRepositoryProvider);
  final env = await envRepo.createEnvironment('Restart Env');
  await envRepo.saveEnvironment(
    env.copyWith(
      variables: [
        EnvVariable(key: 'base_url', value: 'http://localhost:8080'),
        EnvVariable(key: 'token', value: 'test-token', isSecret: true),
      ],
    ),
  );
  c.read(settingsProvider.notifier)
    ..setActiveEnvironment(env.id)
    ..update((s) => s.copyWith(themeMode: ThemeMode.light));
  await h.until(
    () => c.read(activeEnvironmentProvider)?.name == 'Restart Env',
    what: 'active env',
  );

  // Send three requests through the UI (history), then leave the saved one open.
  await c.read(workspaceProvider.notifier).openSavedRequest(saved.id);
  await h.pumpFor(const Duration(milliseconds: 300));
  for (var i = 0; i < 3; i++) {
    await h.send();
    if (h.success.statusCode != 200) throw TestFailure('send failed');
  }
  await h.pumpFor(const Duration(seconds: 2)); // workspace/settings persistence
  await server.close();
  Harness.record(
    'Restart write',
    detail:
        'collection, folder, 2 requests, env (secret token), 3 history entries, light theme',
  );
}

Future<void> _verify(
  Harness h,
  ProviderContainer c, {
  required bool secretsExpected,
}) async {
  final trees = await c.read(collectionRepositoryProvider).watchTrees().first;
  final tree = trees.singleWhere((t) => t.collection.name == 'Restart Check');
  if (tree.allFolders.single.name != 'Folder A') {
    throw TestFailure('folder missing');
  }
  final names = tree.allRequests.map((r) => r.name).toSet();
  if (!names.contains('Saved GET')) throw TestFailure('saved request missing');

  final tabs = c.read(workspaceProvider).tabs.whereType<RequestTab>();
  if (!tabs.any((t) => t.title == 'Saved GET')) {
    throw TestFailure('open tab not restored');
  }
  await h.untilFound(find.text('Restart Check'));

  final envs = await c
      .read(environmentRepositoryProvider)
      .watchEnvironments()
      .first;
  final env = envs.singleWhere((e) => e.name == 'Restart Env');
  final token = env.variables.singleWhere((v) => v.key == 'token');
  if (token.value != 'test-token') throw TestFailure('env token not restored');
  if (c.read(settingsProvider).activeEnvironmentId != env.id) {
    throw TestFailure('active env lost');
  }
  if (c.read(settingsProvider).themeMode != ThemeMode.light) {
    throw TestFailure('theme lost');
  }

  final history = await c.read(historyRepositoryProvider).watch().first;
  if (history.length < 3) throw TestFailure('history lost (${history.length})');
  if (history.first.statusCode != 200) throw TestFailure('history status lost');

  if (secretsExpected) {
    final secretReq = tree.allRequests.singleWhere(
      (r) => r.name == 'Secret POST',
    );
    final hydrated = await c
        .read(collectionRepositoryProvider)
        .getRequest(secretReq.id);
    if (hydrated!.auth != const BearerAuth(token: secret)) {
      throw TestFailure('Keychain secret not readable after restart');
    }
    if (!token.isSecret) throw TestFailure('secret flag lost');
    Harness.record(
      'Restart verify (process 2)',
      detail:
          'collections, open tab, env, active env, theme, ${history.length} history entries; Keychain secrets read back',
    );
  } else {
    if (names.contains('Secret POST')) {
      throw TestFailure('secret request should have been removed');
    }
    Harness.record(
      'Restart verify (process 3, after release app run)',
      detail: 'all data intact after the release binary opened and closed it',
    );
  }
}

/// Removes secrets before the separately signed release binary opens the
/// data (reading another binary's legacy-Keychain items would prompt).
Future<void> _dropSecrets(ProviderContainer c) async {
  final repo = c.read(collectionRepositoryProvider);
  final trees = await repo.watchTrees().first;
  final secretReq = trees
      .expand((t) => t.allRequests)
      .singleWhere((r) => r.name == 'Secret POST');
  await repo.deleteRequest(secretReq.id);
  final envRepo = c.read(environmentRepositoryProvider);
  final env = (await envRepo.watchEnvironments().first).singleWhere(
    (e) => e.name == 'Restart Env',
  );
  final tokenVar = env.variables.singleWhere((v) => v.key == 'token');
  await envRepo.saveEnvironment(
    env.copyWith(
      variables: [
        for (final v in env.variables)
          v.key == 'token' ? v.copyWith(isSecret: false) : v,
      ],
    ),
  );
  final keys = [
    VaultKeys.requestAuth(secretReq.id, 'token'),
    VaultKeys.envVariable(env.id, tokenVar.id),
  ];
  for (final k in keys) {
    if (await Harness.keychainHas(k)) {
      throw TestFailure('Keychain item $k not deleted');
    }
  }
  Harness.record(
    'Keychain delete after restart',
    detail: 'request token and env secret removed from Keychain',
  );
}
