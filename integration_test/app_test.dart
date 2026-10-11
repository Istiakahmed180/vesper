import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vesper/app.dart';
import 'package:vesper/core/di/app_providers.dart';
import 'package:vesper/core/security/secret_vault.dart';
import 'package:vesper/core/storage/app_database.dart';
import 'package:vesper/features/environments/domain/environment_models.dart';
import 'package:vesper/features/workspaces/presentation/workspace_providers.dart';

import '../test/support/test_server.dart';

/// Directory for screenshots (pass --dart-define=SHOT_DIR=/path to keep them).
const shotDir = String.fromEnvironment('SHOT_DIR');

final _boundary = GlobalKey();

Future<void> shot(WidgetTester tester, String name) async {
  if (shotDir.isEmpty) return;
  await tester.pump(const Duration(milliseconds: 200));
  final boundary =
      _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 1.5);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  await File('$shotDir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
}

Future<void> pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) return;
  }
  await shot(tester, 'timeout_failure');
  throw TestFailure('Timed out waiting for $finder');
}

Finder urlField() => find.ancestor(
  of: find.text('Enter a URL, {{base_url}}/path, or paste a cURL command'),
  matching: find.byType(TextField),
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late TestServer server;
  late AppDatabase db;
  late ProviderContainer container;

  setUpAll(() async => server = await TestServer.start());
  tearDownAll(() => server.close());

  Future<void> launch(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
  }) async {
    db = AppDatabase(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        vaultProvider.overrideWithValue(InMemoryVault()),
      ],
      retry: (_, _) => null,
    );
    await tester.binding.setSurfaceSize(size);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(key: _boundary, child: const VesperApp()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
  }

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  testWidgets('send a request, save it, use environments and cURL', (
    tester,
  ) async {
    await launch(tester);
    await shot(tester, '01_empty');

    // Send a real GET request.
    await tester.tap(urlField());
    await tester.enterText(urlField(), '${server.baseUrl}/echo?greeting=hello');
    await tester.pump();
    expect(
      find.text('greeting'),
      findsWidgets,
      reason: 'params table syncs from URL',
    );
    await tester.tap(find.text('Send'));
    await pumpUntil(tester, find.textContaining('200'));
    await pumpUntil(tester, find.textContaining('"greeting"'));
    await shot(tester, '02_response');

    // Save into a new collection.
    await tester.tap(find.text('Save'));
    await pumpUntil(tester, find.text('Save request'));
    final dialog = find.byType(AlertDialog);
    await tester.tap(
      find.descendant(of: dialog, matching: find.text('New collection')),
    );
    await pumpUntil(
      tester,
      find.descendant(
        of: dialog,
        matching: find.byType(DropdownButtonFormField<String>),
      ),
    );
    await tester.tap(
      find.descendant(
        of: dialog,
        matching: find.widgetWithText(FilledButton, 'Save'),
      ),
    );
    await pumpUntil(tester, find.text('Saved "Untitled request"'));
    await pumpUntil(tester, find.text('Untitled request'));

    // Environment variables resolve in the URL; 1 MB JSON renders.
    final env = await container
        .read(environmentRepositoryProvider)
        .createEnvironment(
          'Development',
          variables: [EnvVariable(key: 'base_url', value: server.baseUrl)],
        );
    await container
        .read(activeWorkspaceIdProvider.notifier)
        .setActiveEnvironment(env.id);
    await pumpUntil(tester, find.text('Development'));
    await tester.tap(urlField());
    await tester.enterText(urlField(), '{{base_url}}/large?bytes=1048576');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('base_url'), findsWidgets);
    await tester.tap(find.text('Send'));
    await pumpUntil(tester, find.textContaining('1.00 MB'));
    await shot(tester, '03_environment_large');

    // Pasting a cURL command into the URL bar replaces the request.
    await tester.tap(urlField());
    await tester.enterText(
      urlField(),
      "curl -X POST ${server.baseUrl}/echo -H 'Content-Type: application/json' -d '{\"name\":\"vesper\"}'",
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('POST'), findsWidgets);
    await tester.tap(find.text('Body').first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Send'));
    await pumpUntil(tester, find.textContaining(r'\"name\"'));
    await shot(tester, '04_curl_post');

    // Error state: connection refused is shown, not thrown.
    final port = await unusedPort();
    await tester.tap(urlField());
    await tester.enterText(urlField(), 'http://127.0.0.1:$port/');
    await tester.tap(find.text('Send'));
    await pumpUntil(tester, find.text('Connection refused'));
    await shot(tester, '05_error');

    // Settings screen.
    await tester.tap(find.byTooltip('Settings (⌘,)').first);
    await pumpUntil(tester, find.text('Appearance'));
    await shot(tester, '06_settings');
  });

  testWidgets('10 MB JSON response stays responsive', (tester) async {
    await launch(tester);
    await tester.tap(urlField());
    await tester.enterText(urlField(), '${server.baseUrl}/json?items=45000');
    final sw = Stopwatch()..start();
    await tester.tap(find.text('Send'));
    await pumpUntil(
      tester,
      find.textContaining('"total"', findRichText: true),
      timeout: const Duration(seconds: 30),
    );
    sw.stop();
    // ignore: avoid_print
    print(
      'PERF 10MB JSON: received, formatted and rendered in ${sw.elapsedMilliseconds} ms',
    );
    expect(find.textContaining('MB'), findsWidgets);
    await shot(tester, '07_large_json');

    // Folding and search work on the large document.
    await pumpUntil(tester, find.byTooltip('Collapse all'));
    await tester.tap(find.byTooltip('Collapse all'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byTooltip('Search (⌘F)'));
    await tester.pump();
    await tester.enterText(
      find.widgetWithText(TextField, 'Find in body'),
      'user44999@',
    );
    await pumpUntil(
      tester,
      find.text('1/1'),
      timeout: const Duration(seconds: 10),
    );
    await shot(tester, '08_large_json_search');
  });

  testWidgets('layout holds at the minimum window size', (tester) async {
    await launch(tester, size: const Size(980, 620));
    await tester.tap(urlField());
    await tester.enterText(urlField(), '${server.baseUrl}/echo');
    await tester.tap(find.text('Send'));
    await pumpUntil(tester, find.textContaining('200'));
    for (final section in [
      'Authorization',
      'Headers',
      'Body',
      'Cookies',
      'Settings',
    ]) {
      await tester.tap(find.text(section).first);
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.tap(find.byTooltip('Environments'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('History'));
    await tester.pump(const Duration(milliseconds: 300));
    await shot(tester, '09_min_size');
  });
}
