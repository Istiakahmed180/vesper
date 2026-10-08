// macOS verification suite. Run release-compiled (AOT) with:
//   flutter drive --profile -d macos --driver test_driver/integration_test.dart \
//     --target integration_test/macos_verification.dart --dart-define=VESPER_E2E=1
//   WARNING: wipes the local Vesper data and Keychain items of this machine.
//
// It boots the app through the same `bootstrap()` as `main()` — real window
// manager, real SQLite file in Application Support and the real macOS
// Keychain — and drives the UI against local HTTP servers.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:vesper/bootstrap.dart';
import 'package:vesper/core/config/app_config.dart';
import 'package:vesper/core/di/app_providers.dart';
import 'package:vesper/core/logging/app_logger.dart';
import 'package:vesper/core/security/secret_vault.dart';
import 'package:vesper/features/api_client/domain/models/http_method.dart';
import 'package:vesper/features/api_client/domain/models/request_auth.dart';
import 'package:vesper/features/api_client/domain/models/request_body.dart';
import 'package:vesper/features/api_client/domain/services/curl_parser.dart';
import 'package:vesper/features/api_client/presentation/request/auth_editor.dart';
import 'package:vesper/features/api_client/presentation/request/body_editor.dart';
import 'package:vesper/features/api_client/presentation/response/response_panel.dart';
import 'package:vesper/features/collections/domain/collection_models.dart';
import 'package:vesper/features/collections/presentation/collection_tree_view.dart';
import 'package:vesper/features/environments/presentation/environment_editor.dart';
import 'package:vesper/features/environments/presentation/environment_providers.dart';
import 'package:vesper/features/environments/presentation/environments_panel.dart';
import 'package:vesper/features/github/data/github_api.dart';
import 'package:vesper/features/github/presentation/github_providers.dart';
import 'package:vesper/features/import_export/domain/collection_codec.dart';
import 'package:vesper/features/import_export/domain/import_service.dart';
import 'package:vesper/features/sync/domain/sync_service.dart';
import 'package:vesper/features/sync/presentation/sync_dialog.dart';
import 'package:vesper/features/workspace/presentation/response_controller.dart';
import 'package:vesper/features/workspace/presentation/shell_state.dart';
import 'package:vesper/features/workspace/presentation/tab_strip.dart';
import 'package:vesper/features/workspace/presentation/workspace_controller.dart';
import 'package:vesper/shared/widgets/code/code_editor.dart';
import 'package:vesper/shared/widgets/key_value_editor.dart';
import 'package:window_manager/window_manager.dart';

import '../test/support/fake_github.dart';
import '../test/support/test_server.dart';
import 'support/harness.dart';

// Unique markers so leaked secrets can be found byte-for-byte on disk.
const bearerSecret = 'VSPR-BEARER-SECRET-7f3a';
const basicSecret = 'VSPR-BASIC-PASS-91c2';
const apiKeySecret = 'VSPR-APIKEY-55d0';
const curlSecret = 'VSPR-CURL-TOKEN-e81b';
const envSecret = 'test-token';

late ProviderContainer container;
late TestServer server;
late TestServer server8080;
late String base;
final perf = <String, Object?>{};
const only = String.fromEnvironment('ONLY');

/// This suite uses the real Application Support directory and Keychain of
/// co.tdevs.vesper and wipes them. It only runs when explicitly enabled.
const enabled =
    String.fromEnvironment('VESPER_E2E') == '1' ||
    String.fromEnvironment('VESPER_E2E') == 'true';

void check(
  String name,
  Future<void> Function(WidgetTester) body,
) => testWidgets(
  name,
  body,
  skip: !enabled || (only.isNotEmpty && !only.split('+').any(name.startsWith)),
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    if (!enabled) return;
    // Start from an empty data directory (only test data lives here).
    final dir = await Harness.supportDir();
    for (final n in [
      'vesper.sqlite',
      'vesper.sqlite-wal',
      'vesper.sqlite-shm',
    ]) {
      final f = File(p.join(dir.path, n));
      if (f.existsSync()) f.deleteSync();
    }
    server = await TestServer.start();
    server8080 = await TestServer.start(port: 8080);
    base = server.baseUrl;
    container = await bootstrap(installErrorHandlers: false);
  });

  tearDownAll(() async {
    if (!enabled) return;
    // Leave no test data behind: database rows and Keychain items.
    await container.read(databaseProvider).wipe();
    await container.read(vaultProvider).clear();
    await server.close();
    await server8080.close();
    binding.reportData = {
      ...?binding.reportData,
      'perf': perf,
      'checks': Harness.results,
    };
  });

  Future<Harness> start(WidgetTester tester) async {
    await tester.pumpWidget(Harness.wrap(container));
    final h = Harness(tester, container);
    await h.pumpFor(const Duration(milliseconds: 400));
    container
        .read(shellProvider.notifier)
        .showSection(ShellSection.collections);
    await h.pumpFor(const Duration(milliseconds: 200));
    return h;
  }

  Finder tree(String text) => find.descendant(
    of: find.byType(CollectionTreeView),
    matching: find.text(text),
  );

  /// Closes the active tab, answering "Don't save" for unsaved drafts.
  Future<void> closeActiveTab(Harness h) async {
    final before = h.ws.tabs.length;
    final id = h.tabId;
    await h.tap(
      find.descendant(
        of: find.byKey(ValueKey(id)),
        matching: find.byTooltip('Close (⌘W)'),
      ),
    );
    if (find.text('Unsaved changes').evaluate().isNotEmpty) {
      await h.tap(find.widgetWithText(TextButton, "Don't save"));
    }
    await h.until(
      () => h.ws.tabs.length == before - 1 || (before == 1 && h.tabId != id),
      what: 'tab closed',
    );
  }

  Future<void> addHeader(Harness h, String key, String value) async {
    await h.requestSection('Headers');
    final editor = find.byType(KeyValueEditor);
    await h.type(h.fieldWithHint('Header', within: editor), key);
    await h.type(h.fieldWithHint('Value', within: editor), value);
  }

  Future<void> jsonBody(Harness h, String json) async {
    await h.requestSection('Body');
    await h.tap(
      find.descendant(of: find.byType(BodyEditor), matching: find.text('JSON')),
    );
    await h.type(
      find.descendant(
        of: find.byType(CodeEditor),
        matching: find.byType(TextField),
      ),
      json,
    );
  }

  Future<void> chooseAuth(Harness h, String label) async {
    await h.requestSection('Authorization');
    await h.tap(
      find.descendant(
        of: find.byType(AuthEditor),
        matching: find.byType(DropdownButtonFormField<AuthType>),
      ),
    );
    await h.tap(find.text(label).last);
  }

  Finder authFields() => find.descendant(
    of: find.byType(AuthEditor),
    matching: find.byType(TextField),
  );

  /// Taps [label] in the topmost dialog (a confirmation can sit on top of
  /// another dialog that has a button with the same label).
  Future<void> confirm(Harness h, String label) async {
    await h.untilFound(find.byType(AlertDialog));
    final top = find.byType(AlertDialog).evaluate().last;
    await h.tap(
      find.descendant(
        of: find.byElementPredicate((e) => identical(e, top)),
        matching: find.widgetWithText(FilledButton, label),
      ),
    );
  }

  Future<void> prompt(Harness h, String text, String confirmLabel) async {
    await h.type(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      text,
    );
    await confirm(h, confirmLabel);
    await h.pumpFor(const Duration(milliseconds: 300));
  }

  check('01 startup renders the main UI', (tester) async {
    final h = await start(tester);
    expect(find.text('No collections yet'), findsOneWidget);
    expect(find.text('Send'), findsOneWidget);
    expect(find.byTooltip('Collections'), findsOneWidget);
    final size = await windowManager.getSize();
    expect(size.width, greaterThanOrEqualTo(minimumWindowSize.width));
    await h.shot('01_startup_dark');
    Harness.record(
      'Startup',
      detail:
          'window ${size.width.toInt()}x${size.height.toInt()}, real SQLite + Keychain',
    );
  });

  check('02 HTTP methods, query, headers, JSON body, response metadata', (
    tester,
  ) async {
    final h = await start(tester);
    for (final m in HttpMethod.values) {
      if (m != HttpMethod.get) await h.newTab();
      await h.chooseMethod(m.value);
      await h.setUrl('$base/echo?alpha=1&beta=two words');
      await addHeader(h, 'X-Verify', 'm-${m.value}');
      final hasBody =
          m == HttpMethod.post || m == HttpMethod.put || m == HttpMethod.patch;
      if (hasBody) await jsonBody(h, '{"method":"${m.value}","n":1}');
      await h.send();
      final r = h.success;
      expect(r.statusCode, 200);
      expect(r.method, m);
      expect(find.textContaining('200 OK'), findsWidgets);
      expect(find.textContaining('Time', findRichText: true), findsWidgets);
      expect(find.textContaining('Size', findRichText: true), findsWidgets);
      if (m == HttpMethod.head) {
        expect(r.bodyBytes, isEmpty);
        expect(r.header('content-type'), contains('json'));
      } else {
        expect(h.echo['method'], m.value);
        expect(h.echo['query'], {'alpha': '1', 'beta': 'two words'});
        expect(h.echoHeaders['x-verify'], 'm-${m.value}');
        if (hasBody) {
          expect(jsonDecode(h.echo['body']! as String), {
            'method': m.value,
            'n': 1,
          });
          expect(h.echoHeaders['content-type'], 'application/json');
        }
      }
      if (m == HttpMethod.post) {
        await h.responseSection('Headers');
        expect(
          find.descendant(
            of: find.byType(ResponsePanel),
            matching: find.text('content-type'),
          ),
          findsOneWidget,
        );
        await h.shot('02_post_response_headers');
        await h.responseSection('Body');
      }
      Harness.record(
        'HTTP ${m.value}',
        detail:
            '${r.statusCode}, ${r.duration.inMilliseconds} ms, ${r.bodySize} B',
      );
    }
  });

  check('03 form bodies, multipart and binary upload', (tester) async {
    final h = await start(tester);
    final tmp = await Directory.systemTemp.createTemp('vesper_verify');
    addTearDown(() => tmp.delete(recursive: true));

    // x-www-form-urlencoded through the table UI.
    await h.newTab();
    await h.chooseMethod('POST');
    await h.setUrl('$base/echo');
    await h.requestSection('Body');
    await h.tap(
      find.descendant(
        of: find.byType(BodyEditor),
        matching: find.text('x-www-form-urlencoded'),
      ),
    );
    final kv = find.byType(KeyValueEditor);
    await h.type(h.fieldWithHint('Key', within: kv), 'name');
    await h.type(h.fieldWithHint('Value', within: kv), 'Ada Lovelace & co');
    await h.send();
    expect(h.echo['body'], 'name=Ada+Lovelace+%26+co');
    expect(h.echoHeaders['content-type'], 'application/x-www-form-urlencoded');
    Harness.record('Form urlencoded', detail: h.echo['body']! as String);

    // Multipart: text field via UI, file chosen programmatically (the native
    // file dialog cannot be automated).
    final upload = File(p.join(tmp.path, 'avatar.txt'))
      ..writeAsStringSync('hello-multipart');
    await h.tap(
      find.descendant(
        of: find.byType(BodyEditor),
        matching: find.text('Form Data'),
      ),
    );
    await h.type(h.fieldWithHint('Key'), 'field');
    await h.type(h.fieldWithHint('Value'), 'text-value');
    container
        .read(workspaceProvider.notifier)
        .updateDraft(
          h.tabId,
          (d) => d.copyWith(
            url: '$base/upload',
            body: d.body.copyWith(
              formData: [
                ...d.body.formData,
                FormDataField(
                  key: 'avatar',
                  kind: FormFieldKind.file,
                  filePath: upload.path,
                ),
              ],
            ),
          ),
        );
    await h.pumpFor(const Duration(milliseconds: 200));
    expect(find.text('avatar.txt'), findsOneWidget);
    await h.send();
    expect(h.echo['contentType'], 'multipart/form-data');
    expect(
      h.echo['raw'],
      allOf(
        contains('hello-multipart'),
        contains('filename="avatar.txt"'),
        contains('text-value'),
      ),
    );
    await h.shot('03_multipart');
    Harness.record(
      'Multipart upload',
      detail: 'text field + file part received',
    );

    // Binary body.
    final blob = File(p.join(tmp.path, 'blob.bin'))
      ..writeAsBytesSync(List.generate(4096, (i) => i % 256));
    container
        .read(workspaceProvider.notifier)
        .updateDraft(
          h.tabId,
          (d) => d.copyWith(
            url: '$base/count',
            body: RequestBody(type: BodyType.binary, binaryFilePath: blob.path),
          ),
        );
    await h.pumpFor(const Duration(milliseconds: 200));
    expect(find.text('blob.bin'), findsOneWidget);
    await h.send();
    expect(h.echo['length'], 4096);
    Harness.record('Binary file upload', detail: '4096 bytes received');
  });

  check('04 error handling never crashes', (tester) async {
    final h = await start(tester);
    await h.newTab();

    Future<void> expectFailure(
      String url,
      String title, {
      String? message,
    }) async {
      await h.setUrl(url);
      await h.send();
      expect(h.response, isA<Object>());
      expect(
        find.descendant(
          of: find.byType(ResponsePanel),
          matching: find.text(title),
        ),
        findsOneWidget,
        reason: url,
      );
      if (message != null) expect(h.failureMessage, contains(message));
      Harness.record('Error: $title', detail: h.failureMessage);
    }

    await expectFailure('http://', 'Invalid URL');
    await expectFailure(
      'ftp://example.com/file',
      'Invalid URL',
      message: 'Unsupported protocol',
    );
    await expectFailure(
      '{{not_defined}}/users',
      'Invalid URL',
      message: '{{not_defined}}',
    );
    await expectFailure(
      'http://127.0.0.1:${await unusedPort()}/',
      'Connection refused',
    );
    await expectFailure('http://vesper-verify.invalid/', 'Host not found');
    await h.shot('04_dns_error');

    // Timeout via the per-request setting.
    await h.requestSection('Settings');
    await h.type(h.fieldWithHint('Global (30000)'), '700');
    await expectFailure(
      '$base/slow?ms=3000',
      'Request timed out',
      message: '0.7 seconds',
    );

    // Cancel while loading.
    await h.requestSection('Settings');
    await h.type(
      find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(TextField),
          )
          .first,
      '',
    );
    await h.setUrl('$base/slow?ms=4000');
    await h.tap(find.text('Send'));
    await h.untilFound(find.text('Cancel'));
    await h.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
    await h.untilFound(find.text('Request cancelled'));
    Harness.record(
      'Cancel request',
      detail: 'loading state cancelled from the URL bar',
    );

    // The app is still fully usable afterwards.
    await h.setUrl('$base/echo');
    await h.send();
    expect(h.success.statusCode, 200);
    Harness.record('Recovery after errors', detail: 'next request succeeded');
  });

  check('05 large JSON response (~10 MB)', (tester) async {
    final h = await start(tester);
    await h.newTab();
    await h.setUrl('$base/json?items=60000');
    final rssBefore = ProcessInfo.currentRss;
    final worstFrames = <int>[];
    final phaseWorst = <String, int>{};
    var mark = 0;
    void endPhase(String name) {
      final slice = worstFrames.sublist(mark);
      mark = worstFrames.length;
      phaseWorst[name] = slice.isEmpty
          ? 0
          : slice.reduce((a, b) => a > b ? a : b);
    }

    void onTimings(List<FrameTiming> t) =>
        worstFrames.addAll(t.map((f) => f.totalSpan.inMilliseconds));
    SchedulerBinding.instance.addTimingsCallback(onTimings);

    final sw = Stopwatch()..start();
    late final int networkMs;
    await binding.traceAction(() async {
      await h.send(timeout: const Duration(seconds: 60));
      networkMs = h.success.duration.inMilliseconds;
      await h.untilFound(
        find.textContaining('"total"', findRichText: true),
        timeout: const Duration(seconds: 60),
      );
      await h.pumpFor(const Duration(milliseconds: 300));
    }, reportKey: 'large_json_render_timeline');
    final r = h.success;
    await h.untilFound(
      find.textContaining('"total"', findRichText: true),
      timeout: const Duration(seconds: 60),
    );
    sw.stop();
    await h.pumpFor(const Duration(milliseconds: 300));
    endPhase('sendAndRender');
    final rssLoaded = ProcessInfo.currentRss;
    await h.shot('05_large_pretty');

    // Search across ~720k lines.
    final searchSw = Stopwatch()..start();
    await h.tap(find.byTooltip('Search (⌘F)'));
    await h.type(h.fieldWithHint('Find in body'), 'user59999@');
    await h.untilFound(find.text('1/1'));
    searchSw.stop();
    await h.pumpFor(const Duration(milliseconds: 300));
    endPhase('search');
    await h.shot('05_large_search');

    // Fold / unfold.
    await h.tap(find.byTooltip('Collapse all'));
    await h.untilFound(find.textContaining('lines', findRichText: true));
    await h.tap(find.byTooltip('Expand all'));
    await h.pumpFor(const Duration(milliseconds: 300));

    // Scrolling performance.
    final list = find
        .descendant(
          of: find.byType(ResponsePanel),
          matching: find.byType(Scrollable),
        )
        .last;
    await binding.watchPerformance(() async {
      for (var i = 0; i < 6; i++) {
        await tester.fling(list, const Offset(0, -2500), 6000);
        await h.pumpFor(const Duration(milliseconds: 250));
      }
    }, reportKey: 'scroll_10mb_json');
    endPhase('foldAndScroll');

    // Raw view of the same body.
    final rawSw = Stopwatch()..start();
    await h.tap(find.text('Raw'));
    await h.untilFound(
      find.textContaining('{"total":60000', findRichText: true),
      timeout: const Duration(seconds: 30),
    );
    rawSw.stop();
    await h.pumpFor(const Duration(milliseconds: 300));
    endPhase('raw');
    await h.shot('05_large_raw');
    SchedulerBinding.instance.removeTimingsCallback(onTimings);

    // Memory is released when the tab closes.
    await closeActiveTab(h);
    await h.pumpFor(const Duration(seconds: 2));
    final rssAfterClose = ProcessInfo.currentRss;

    // Leak check: load and close the 10 MB response three more times; memory
    // must plateau instead of growing by ~a response each cycle.
    final cycles = <int>[];
    for (var i = 0; i < 3; i++) {
      await h.newTab();
      await h.setUrl('$base/json?items=60000');
      await h.send(timeout: const Duration(seconds: 60));
      await h.untilFound(
        find.textContaining('"total"', findRichText: true),
        timeout: const Duration(seconds: 60),
      );
      await closeActiveTab(h);
      await h.pumpFor(const Duration(seconds: 2));
      cycles.add(ProcessInfo.currentRss ~/ (1 << 20));
    }

    worstFrames.sort();
    final worst = worstFrames.isEmpty ? 0 : worstFrames.last;
    perf['large_json'] = {
      'bodyBytes': r.bodySize,
      'networkMs': networkMs,
      'sendToRenderedMs': sw.elapsedMilliseconds,
      'searchMs': searchSw.elapsedMilliseconds,
      'rawViewMs': rawSw.elapsedMilliseconds,
      'worstFrameMs': worst,
      'worstFrameByPhaseMs': phaseWorst,
      'rssBeforeMB': rssBefore ~/ (1 << 20),
      'rssLoadedMB': rssLoaded ~/ (1 << 20),
      'rssAfterCloseMB': rssAfterClose ~/ (1 << 20),
      'rssAfterRepeatCyclesMB': cycles,
    };
    expect(r.bodySize, greaterThan(9 * 1024 * 1024));
    expect(
      cycles.last - cycles.first,
      lessThan(120),
      reason: 'memory grows with every 10 MB load: $cycles',
    );
    // Formatting runs on a background isolate: no frame may block for seconds.
    expect(worst, lessThan(1000), reason: 'UI thread blocked for ${worst}ms');
    Harness.record('Large JSON', detail: jsonEncode(perf['large_json']));
  });

  check(
    '06 collections: create, folder, rename, duplicate, move, delete, save, open',
    (tester) async {
      final h = await start(tester);
      Future<CollectionTree> treeOf(String name) async {
        final trees = await container
            .read(collectionRepositoryProvider)
            .watchTrees()
            .first;
        return trees.firstWhere((t) => t.collection.name == name);
      }

      await h.tap(find.byTooltip('New collection (⌘⇧N)'));
      await prompt(h, 'Verify API', 'Create');
      await h.untilFound(tree('Verify API'));

      await h.rightClick(tree('Verify API'));
      await h.tap(h.menuItem('Add folder'));
      await prompt(h, 'Users', 'Create');
      await h.untilFound(tree('Users'));

      await h.rightClick(tree('Users'));
      await h.tap(h.menuItem('Add request'));
      await h.until(
        () => h.ws.activeTab?.title == 'New request',
        what: 'new saved request tab',
      );
      await h.setUrl('$base/echo?page=1');
      await h.tap(find.widgetWithText(OutlinedButton, 'Save'));
      await h.untilFound(find.text('Saved'));

      await h.rightClick(
        find.descendant(
          of: find.byType(ListView),
          matching: find.text('New request'),
        ),
      );
      await h.tap(h.menuItem('Rename'));
      await prompt(h, 'List users', 'Save');
      await h.untilFound(
        find.descendant(
          of: find.byType(ListView),
          matching: find.text('List users'),
        ),
      );
      expect(h.tab.draft.name, 'List users', reason: 'open tab follows rename');

      await h.rightClick(
        find.descendant(
          of: find.byType(ListView),
          matching: find.text('List users'),
        ),
      );
      await h.tap(h.menuItem('Duplicate'));
      await h.untilFound(tree('List users copy'));
      Harness.record('Collections: create/folder/request/rename/duplicate');

      // Drag the copy out of the folder onto the collection root.
      final gesture = await tester.startGesture(
        tester.getCenter(tree('List users copy')),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveBy(const Offset(0, -10));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveTo(tester.getCenter(tree('Verify API')));
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.up();
      await h.pumpFor(const Duration(milliseconds: 500));
      final moved = (await treeOf(
        'Verify API',
      )).children.whereType<RequestNode>().map((n) => n.name);
      expect(moved, contains('List users copy'));
      Harness.record(
        'Collections: drag & drop move',
        detail: 'request moved from folder to collection root',
      );

      await h.rightClick(tree('List users copy'));
      await h.tap(h.menuItem('Delete'));
      await confirm(h, 'Delete');
      await h.until(
        () => tree('List users copy').evaluate().isEmpty,
        what: 'deleted',
      );
      Harness.record('Collections: delete with confirmation');

      // Save a brand new request through the Save dialog, then reopen it.
      await h.newTab();
      await h.setUrl('$base/echo?health=1');
      await h.tap(find.widgetWithText(OutlinedButton, 'Save'));
      await h.untilFound(find.text('Save request'));
      await h.type(
        find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(TextField),
            )
            .first,
        'Health check',
      );
      await confirm(h, 'Save');
      await h.untilFound(find.text('Saved "Health check"'));
      await closeActiveTab(h);
      await h.tap(
        find.descendant(
          of: find.byType(ListView),
          matching: find.text('Health check'),
        ),
      );
      await h.until(
        () => h.ws.activeTab?.title == 'Health check',
        what: 'opened saved request',
      );
      expect(h.tab.draft.url, '$base/echo?health=1');
      Harness.record('Collections: save via dialog and reopen');

      await h.rightClick(tree('Verify API'));
      await h.tap(h.menuItem('Rename'));
      await prompt(h, 'Verify API v2', 'Save');
      await h.rightClick(tree('Verify API v2'));
      await h.tap(h.menuItem('Duplicate'));
      await h.untilFound(tree('Verify API v2 copy'));
      await h.rightClick(tree('Verify API v2 copy'));
      await h.tap(h.menuItem('Delete'));
      await confirm(h, 'Delete');
      await h.until(
        () => tree('Verify API v2 copy').evaluate().isEmpty,
        what: 'collection deleted',
      );
      await h.shot('06_collections');
      Harness.record('Collections: rename/duplicate/delete collection');
    },
  );

  check('07 environments resolve in URL, headers, body and auth', (
    tester,
  ) async {
    final h = await start(tester);
    await h.tap(find.byType(EnvironmentSelector));
    await h.tap(h.menuItem('New environment…'));
    await prompt(h, 'Local', 'Create');
    await h.untilFound(find.byType(EnvironmentEditor));
    final editor = find.byType(EnvironmentEditor);
    await h.type(h.fieldWithHint('variable_name', within: editor), 'base_url');
    await h.type(
      h.fieldWithHint('value', within: editor),
      'http://localhost:8080',
    );
    await h.type(h.fieldWithHint('variable_name', within: editor), 'token');
    await h.type(h.fieldWithHint('value', within: editor), envSecret);
    await h.shot('07_env_rows');
    await h.tap(
      find.descendant(of: editor, matching: find.byType(Switch)).at(1),
    );
    await h.tap(
      find.descendant(
        of: editor,
        matching: find.widgetWithText(FilledButton, 'Save'),
      ),
    );
    await h.tap(find.widgetWithText(OutlinedButton, 'Set active'));
    await h.until(
      () => container.read(activeEnvironmentProvider)?.name == 'Local',
      what: 'active env',
    );
    await h.shot('07_env_editor');

    await h.newTab();
    await h.chooseMethod('POST');
    await h.setUrl('{{base_url}}/echo?t={{token}}');
    await addHeader(h, 'X-Token', '{{token}}');
    await jsonBody(h, '{"token":"{{token}}"}');
    await chooseAuth(h, 'Bearer Token');
    await h.type(authFields().first, '{{token}}');
    expect(
      find.textContaining('http://localhost:8080', findRichText: true),
      findsWidgets,
    );
    await h.send();
    expect(h.echo['query'], {'t': envSecret});
    expect(h.echoHeaders['x-token'], envSecret);
    expect(jsonDecode(h.echo['body']! as String), {'token': envSecret});
    expect(h.echoHeaders['authorization'], 'Bearer $envSecret');
    await h.shot('07_env_request');
    Harness.record(
      'Environment substitution',
      detail: 'URL, query, header, body and bearer auth resolved',
    );
  });

  check('08 history: entries, re-run, delete, clear', (tester) async {
    final h = await start(tester);
    await h.tap(find.byTooltip('History'));
    final entries = await container
        .read(historyRepositoryProvider)
        .watch()
        .first;
    expect(entries.length, greaterThan(10));
    final first = entries.first;
    expect(find.text(first.url), findsWidgets);
    expect(find.textContaining('just now'), findsWidgets);
    expect(find.text('TODAY'), findsOneWidget);
    await h.shot('08_history');

    final tabs = h.ws.tabs.length;
    await h.rightClick(find.text(first.url).first);
    await h.tap(h.menuItem('Re-run'));
    await h.until(() => h.ws.tabs.length == tabs + 1, what: 're-run tab');
    await h.until(
      () => h.response is ResponseSuccess || h.response is ResponseFailure,
      what: 're-run response',
    );
    Harness.record(
      'History: entries and re-run',
      detail:
          '${entries.length} entries, method/url/status/duration/time shown',
    );

    final before =
        (await container.read(historyRepositoryProvider).watch().first).length;
    await h.rightClick(find.text(first.url).first);
    await h.tap(h.menuItem('Delete'));
    await h.pumpFor(const Duration(milliseconds: 400));
    final after =
        (await container.read(historyRepositoryProvider).watch().first).length;
    expect(after, lessThan(before));
    Harness.record('History: delete item');

    await h.tap(find.byTooltip('Clear history'));
    await confirm(h, 'Clear history');
    await h.untilFound(find.text('No history yet'));
    Harness.record('History: clear');
  });

  check('09 authorization types are sent correctly', (tester) async {
    final h = await start(tester);
    await h.newTab();
    await h.setUrl('$base/echo');
    await h.send();
    expect(h.echoHeaders.containsKey('authorization'), isFalse);
    Harness.record('Auth: none');

    await chooseAuth(h, 'Bearer Token');
    await h.type(authFields().first, bearerSecret);
    await h.send();
    expect(h.echoHeaders['authorization'], 'Bearer $bearerSecret');
    Harness.record('Auth: bearer');

    await chooseAuth(h, 'Basic Auth');
    await h.type(authFields().at(0), 'alice');
    await h.type(authFields().at(1), basicSecret);
    await h.send();
    expect(
      h.echoHeaders['authorization'],
      'Basic ${base64.encode(utf8.encode('alice:$basicSecret'))}',
    );
    Harness.record('Auth: basic');

    await chooseAuth(h, 'API Key');
    await h.type(authFields().at(0), 'X-Api-Key');
    await h.type(authFields().at(1), apiKeySecret);
    await h.send();
    expect(h.echoHeaders['x-api-key'], apiKeySecret);
    await h.tap(find.text('Query params'));
    await h.send();
    expect(h.echo['query'], {'X-Api-Key': apiKeySecret});
    Harness.record('Auth: API key (header and query)');

    // Save a request with a bearer secret for the Keychain checks.
    await chooseAuth(h, 'Bearer Token');
    await h.type(authFields().first, bearerSecret);
    await h.tap(find.widgetWithText(OutlinedButton, 'Save'));
    await h.untilFound(find.text('Save request'));
    await h.type(
      find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          )
          .first,
      'Secret request',
    );
    await confirm(h, 'Save');
    await h.untilFound(find.text('Saved "Secret request"'));
  });

  check('10 cURL import and export round trip through the real curl binary', (
    tester,
  ) async {
    final h = await start(tester);
    await h.newTab();
    final command =
        "curl -X PATCH '$base/echo?q=1&r=two' -H 'X-One: 1' -H 'Authorization: Bearer $curlSecret' "
        "-H 'Content-Type: application/json' --data-raw '{\"a\":[1,2]}'";
    await h.setUrl(command);
    await h.untilFound(find.text('cURL command imported'));
    expect(h.tab.draft.method, HttpMethod.patch);
    expect(h.tab.draft.auth, const BearerAuth(token: curlSecret));
    await h.send();
    final vesper = h.echo;
    expect(vesper['method'], 'PATCH');
    expect(vesper['query'], {'q': '1', 'r': 'two'});
    expect(h.echoHeaders['x-one'], '1');
    expect(h.echoHeaders['authorization'], 'Bearer $curlSecret');
    expect(vesper['body'], '{"a":[1,2]}');
    Harness.record(
      'cURL → request',
      detail: 'method, URL, query, headers, JSON body, bearer auth',
    );

    await h.tap(find.byTooltip('More'));
    await h.tap(h.menuItem('Copy as cURL'));
    final generated = (await Clipboard.getData('text/plain'))!.text!;
    final run = await Process.run('/bin/bash', ['-c', '$generated --silent']);
    expect(run.exitCode, 0, reason: '${run.stderr}');
    final viaCurl = (jsonDecode(run.stdout as String) as Map)
        .cast<String, Object?>();
    final curlHeaders = (viaCurl['headers']! as Map).cast<String, Object?>();
    expect(viaCurl['method'], vesper['method']);
    expect(viaCurl['query'], vesper['query']);
    expect(viaCurl['body'], vesper['body']);
    expect(curlHeaders['authorization'], h.echoHeaders['authorization']);
    expect(curlHeaders['x-one'], '1');
    expect(curlHeaders['content-type'], 'application/json');
    expect(
      const CurlParser().parse(generated).request.method,
      HttpMethod.patch,
    );
    Harness.record(
      'Request → cURL',
      detail:
          'generated command executed with /usr/bin/curl; server saw the same request',
    );
  });

  check('11 import / export of collections and environments', (tester) async {
    await start(tester);
    final repo = container.read(collectionRepositoryProvider);
    final trees = await repo.watchTrees().first;
    final source = trees.firstWhere(
      (t) => t.collection.name == 'Verify API v2',
    );
    final secretTree = trees.firstWhere(
      (t) => t.allRequests.any((r) => r.name == 'Secret request'),
    );
    final tmp = await Directory.systemTemp.createTemp('vesper_export');
    addTearDown(() => tmp.delete(recursive: true));
    const codec = VesperCollectionCodec();

    // Export without secrets (default) and with secrets (opt-in).
    final plain = File(p.join(tmp.path, 'plain.vesper.json'))
      ..writeAsStringSync(
        jsonEncode(
          codec.encode(await repo.exportCollection(secretTree.collection.id)),
        ),
      );
    final withSecrets = File(p.join(tmp.path, 'secrets.vesper.json'))
      ..writeAsStringSync(
        jsonEncode(
          codec.encode(
            await repo.exportCollection(
              secretTree.collection.id,
              includeSecrets: true,
            ),
            includeSecrets: true,
          ),
        ),
      );
    expect(plain.readAsStringSync(), isNot(contains(bearerSecret)));
    expect(withSecrets.readAsStringSync(), contains(bearerSecret));
    Harness.record(
      'Export excludes secrets by default',
      detail: 'included only with explicit opt-in',
    );

    // Import the exported file and compare every request.
    final exported = File(p.join(tmp.path, 'source.vesper.json'))
      ..writeAsStringSync(
        jsonEncode(
          codec.encode(await repo.exportCollection(source.collection.id)),
        ),
      );
    final doc = const ImportService()
        .parseCollection(
          await ImportService.decode(exported.readAsStringSync()),
        )
        .value;
    final newId = await repo.importCollection(doc);
    final imported = (await repo.watchTrees().first).firstWhere(
      (t) => t.collection.id == newId,
    );
    String sig(CollectionTree t) => [
      for (final r in t.allRequests)
        '${r.name}|${r.method.value}|${r.url}|${r.headers.map((x) => '${x.key}=${x.value}').join(',')}|${jsonEncode(r.body.toJson())}',
    ].join('\n');
    expect(sig(imported), sig(source));
    expect(
      imported.allFolders.map((f) => f.name),
      source.allFolders.map((f) => f.name),
    );
    Harness.record(
      'Collection export → import',
      detail:
          '${source.requestCount} requests identical (URL, headers, body, method)',
    );

    // Environment round trip; the secret value is not exported.
    final env = container
        .read(environmentsProvider)
        .value!
        .firstWhere((e) => e.name == 'Local');
    final envFile = File(p.join(tmp.path, 'env.json'))
      ..writeAsStringSync(
        jsonEncode(const VesperEnvironmentCodec().encode(env)),
      );
    expect(envFile.readAsStringSync(), isNot(contains(envSecret)));
    final parsedEnv = const ImportService().parseEnvironment(
      await ImportService.decode(envFile.readAsStringSync()),
    );
    expect(parsedEnv.value.variables.map((v) => v.key), ['base_url', 'token']);
    expect(parsedEnv.value.variables.first.value, 'http://localhost:8080');
    expect(parsedEnv.warnings.single, contains('secret'));
    await container
        .read(environmentRepositoryProvider)
        .createEnvironment(
          'Local imported',
          variables: parsedEnv.value.variables,
        );
    Harness.record(
      'Environment export → import',
      detail: 'variables preserved, secret value excluded',
    );

    // Postman v2.1.
    final postman = jsonEncode({
      'info': {
        'name': 'Postman Shop',
        'schema':
            'https://schema.getpostman.com/json/collection/v2.1.0/collection.json',
      },
      'item': [
        {
          'name': 'Orders',
          'item': [
            {
              'name': 'Create order',
              'request': {
                'method': 'POST',
                'header': [
                  {'key': 'X-Shop', 'value': '1'},
                ],
                'url': {'raw': '{{base_url}}/echo?src=postman'},
                'body': {
                  'mode': 'raw',
                  'raw': '{"sku":42}',
                  'options': {
                    'raw': {'language': 'json'},
                  },
                },
              },
            },
          ],
        },
      ],
    });
    final pm = const ImportService().parseCollection(
      await ImportService.decode(postman),
    );
    final pmId = await repo.importCollection(pm.value);
    final pmTree = (await repo.watchTrees().first).firstWhere(
      (t) => t.collection.id == pmId,
    );
    final order = pmTree.allRequests.single;
    expect(order.method, HttpMethod.post);
    expect(order.headers.single.key, 'X-Shop');
    expect(order.body.type, BodyType.json);
    expect(order.url, '{{base_url}}/echo?src=postman');
    Harness.record(
      'Postman v2.1 import',
      detail: 'folder, method, header, URL, JSON body',
    );
  });

  check('12 file upload edge cases', (tester) async {
    final h = await start(tester);
    final tmp = await Directory.systemTemp.createTemp('vesper_files');
    addTearDown(() async {
      await Process.run('chmod', ['-R', 'u+rw', tmp.path]);
      await tmp.delete(recursive: true);
    });
    await h.newTab();
    await h.chooseMethod('POST');
    void binary(String path) => container
        .read(workspaceProvider.notifier)
        .updateDraft(
          h.tabId,
          (d) => d.copyWith(
            url: '$base/count',
            body: RequestBody(type: BodyType.binary, binaryFilePath: path),
          ),
        );
    void multipart(String path) => container
        .read(workspaceProvider.notifier)
        .updateDraft(
          h.tabId,
          (d) => d.copyWith(
            url: '$base/count',
            body: RequestBody(
              type: BodyType.formData,
              formData: [
                FormDataField(
                  key: 'f',
                  kind: FormFieldKind.file,
                  filePath: path,
                ),
              ],
            ),
          ),
        );

    final existing = File(p.join(tmp.path, 'ok.bin'))
      ..writeAsBytesSync(List.filled(1000, 7));
    binary(existing.path);
    await h.send();
    expect(h.echo['length'], 1000);
    Harness.record('Upload: existing file');

    final deleted = File(p.join(tmp.path, 'gone.bin'))..writeAsStringSync('x');
    binary(deleted.path);
    deleted.deleteSync();
    await h.send();
    expect(find.text('File not found'), findsOneWidget);
    expect(h.failureMessage, contains('gone.bin'));
    multipart(deleted.path);
    await h.send();
    expect(h.failureMessage, contains('gone.bin'));
    Harness.record('Upload: deleted file', detail: h.failureMessage);

    binary('/definitely/not/a/real/path.bin');
    await h.send();
    expect(find.text('File not found'), findsOneWidget);
    Harness.record('Upload: invalid path', detail: h.failureMessage);

    final locked = File(p.join(tmp.path, 'locked.bin'))
      ..writeAsStringSync('secret');
    await Process.run('chmod', ['000', locked.path]);
    binary(locked.path);
    await h.send();
    expect(h.response, isA<Object>());
    final lockedMessage = h.failureMessage;
    expect(lockedMessage, contains('locked.bin'));
    multipart(locked.path);
    await h.send();
    expect(h.failureMessage, contains('locked.bin'));
    await h.shot('12_permission_denied');
    Harness.record('Upload: permission denied', detail: lockedMessage);

    // 300 MB file is streamed, not loaded into memory.
    final big = File(p.join(tmp.path, 'big.bin'));
    final raf = big.openSync(mode: FileMode.write);
    final chunk = List.filled(1 << 20, 42);
    for (var i = 0; i < 300; i++) {
      raf.writeFromSync(chunk);
    }
    raf.closeSync();
    final rss = ProcessInfo.currentRss;
    final sw = Stopwatch()..start();
    binary(big.path);
    await h.send(timeout: const Duration(seconds: 120));
    sw.stop();
    expect(h.echo['length'], 300 * (1 << 20));
    final grew = (ProcessInfo.currentRss - rss) ~/ (1 << 20);
    multipart(big.path);
    await h.send(timeout: const Duration(seconds: 120));
    expect(h.echo['length'], greaterThan(300 * (1 << 20)));
    perf['upload_300mb'] = {
      'binaryMs': sw.elapsedMilliseconds,
      'rssGrowthMB': grew,
    };
    Harness.record(
      'Upload: 300 MB file',
      detail:
          '${sw.elapsedMilliseconds} ms, RSS +$grew MB (binary and multipart)',
    );
  });

  check('13 Keychain storage and secret leakage', (tester) async {
    await start(tester);
    final repo = container.read(collectionRepositoryProvider);
    final vault = container.read(vaultProvider);
    expect(vault, isA<SecureStorageVault>());
    final trees = await repo.watchTrees().first;
    final saved = trees
        .expand((t) => t.allRequests)
        .firstWhere((r) => r.name == 'Secret request');
    final tokenKey = VaultKeys.requestAuth(saved.id, 'token');
    expect(await Harness.keychainHas(tokenKey), isTrue);
    expect(
      (await repo.getRequest(saved.id))!.auth,
      const BearerAuth(token: bearerSecret),
    );
    final env = container
        .read(environmentsProvider)
        .value!
        .firstWhere((e) => e.name == 'Local');
    final envKey = VaultKeys.envVariable(
      env.id,
      env.variables.firstWhere((v) => v.key == 'token').id,
    );
    expect(await Harness.keychainHas(envKey), isTrue);
    Harness.record(
      'Keychain write/read',
      detail:
          'request token and secret env var present in login Keychain (service co.tdevs.vesper)',
    );

    // Give the logger and WAL a moment, then scan every persisted byte.
    await Future<void>.delayed(const Duration(seconds: 1));
    final bytes = await Harness.persistedBytes();
    for (final s in [
      bearerSecret,
      basicSecret,
      apiKeySecret,
      curlSecret,
      envSecret,
    ]) {
      expect(
        Harness.bytesContain(bytes, s),
        isFalse,
        reason: '$s found in database or logs',
      );
    }
    final db = container.read(databaseProvider);
    final historyJson = (await db.select(db.historyEntries).get())
        .map((r) => r.requestJson)
        .join();
    expect(historyJson, isNot(contains(bearerSecret)));
    final sync = SyncService(
      collections: repo,
      states: container.read(syncStateStoreProvider),
    );
    final syncDoc = sync.serialize(
      await repo.exportCollection(
        trees
            .firstWhere((t) => t.allRequests.any((r) => r.id == saved.id))
            .collection
            .id,
      ),
    );
    expect(syncDoc, isNot(contains(bearerSecret)));
    Harness.record(
      'No secrets on disk',
      detail:
          'SQLite (+WAL), history, logs and GitHub sync payload scanned for 5 markers',
    );

    // Deleting removes the Keychain items.
    await repo.deleteRequest(saved.id);
    await container
        .read(environmentRepositoryProvider)
        .deleteEnvironment(env.id);
    expect(await Harness.keychainHas(tokenKey), isFalse);
    expect(await Harness.keychainHas(envKey), isFalse);
    Harness.record(
      'Keychain delete',
      detail: 'items removed with their request/environment',
    );
  });

  check('14 Google and GitHub explain missing configuration', (tester) async {
    final h = await start(tester);
    expect(container.read(appConfigProvider).isGoogleConfigured, isFalse);
    await h.tap(find.byTooltip('Settings (⌘,)'));
    await h.tap(find.text('Accounts'));
    await h.untilFound(find.text('Google sign-in is not configured'));
    expect(find.textContaining('GOOGLE_CLIENT_ID'), findsOneWidget);
    expect(find.text('GitHub is not configured'), findsOneWidget);
    expect(find.textContaining('GITHUB_CLIENT_ID'), findsOneWidget);
    await h.shot('14_accounts_not_configured');
    Harness.record(
      'Accounts: missing configuration explained',
      detail: 'GOOGLE_CLIENT_ID / GITHUB_CLIENT_ID named in the UI',
    );
    await h.tap(find.byTooltip('Settings (⌘,)'));
  });

  check(
    '15 GitHub device flow and sync UI against a local GitHub API simulator',
    (tester) async {
      final fake = FakeGitHub()..pollInterval = 1;
      await fake.start();
      addTearDown(() => fake.server.close(force: true));
      final gh = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(container.read(databaseProvider)),
          loggerProvider.overrideWithValue(AppLogger(sinks: [])),
          appConfigProvider.overrideWithValue(
            const AppConfig(
              googleClientId: '',
              googleDesktopClientSecret: '',
              authBackendUrl: '',
              githubClientId: 'verify-client',
              githubScopes: 'read:user repo',
              apiBaseUrl: '',
            ),
          ),
          githubApiProvider.overrideWithValue(
            GitHubApi(
              logger: AppLogger(sinks: []),
              baseUrl: fake.url,
              oauthBaseUrl: fake.url,
            ),
          ),
        ],
        retry: (_, _) => null,
      );
      addTearDown(gh.dispose);
      await tester.pumpWidget(Harness.wrap(gh));
      final h = Harness(tester, gh);
      await h.pumpFor(const Duration(milliseconds: 400));

      // Connect.
      await h.tap(find.byTooltip('Settings (⌘,)'));
      await h.tap(find.text('Accounts'));
      await h.tap(find.text('Connect GitHub'));
      await h.untilFound(
        find.byWidgetPredicate(
          (w) => w is SelectableText && w.data == 'ABCD-1234',
        ),
      );
      await h.shot('15_device_code');
      await h.untilFound(
        find.text('Octo Cat (@octo)'),
        timeout: const Duration(seconds: 30),
      );
      expect(await Harness.keychainHas(VaultKeys.githubSession), isTrue);
      Harness.record(
        'GitHub device flow (simulated API)',
        detail:
            'code shown, polled until authorized, account shown, token in Keychain',
      );

      // Choose repository.
      await h.tap(find.text('Choose…'));
      await h.type(h.fieldWithHint('Search repositories'), 'octo/api');
      await h.tap(find.widgetWithText(ListTile, 'octo/api'));
      await h.tap(find.text('Use this repository'));
      await h.untilFound(find.textContaining('octo/api · main'));
      Harness.record(
        'GitHub repository list and selection',
        detail: '105 repositories paginated',
      );

      final dialog = find.byType(AlertDialog);
      double centerY(Element e) {
        final box = e.renderObject! as RenderBox;
        return box.localToGlobal(box.size.center(Offset.zero)).dy;
      }

      /// The element showing [text] on the same row as the first (topmost)
      /// sync item named [collection], or null.
      Element? onRow(String collection, String text) {
        final names = find.descendant(
          of: dialog,
          matching: find.text(collection),
        );
        final candidates = find
            .descendant(of: dialog, matching: find.text(text))
            .evaluate()
            .toList();
        if (names.evaluate().isEmpty || candidates.isEmpty) return null;
        final y = centerY(h.topmost(names));
        candidates.sort(
          (a, b) => (centerY(a) - y).abs().compareTo((centerY(b) - y).abs()),
        );
        return (centerY(candidates.first) - y).abs() < 30
            ? candidates.first
            : null;
      }

      Future<void> status(String collection, String label) => h.until(
        () => onRow(collection, label) != null,
        what: '$collection is $label',
      );

      Future<void> act(
        String collection,
        String button,
        String confirmLabel,
      ) async {
        await h.until(
          () => onRow(collection, button) != null,
          what: '$button for $collection',
        );
        final box = onRow(collection, button)!.renderObject! as RenderBox;
        await tester.tapAt(box.localToGlobal(box.size.center(Offset.zero)));
        await tester.pump(const Duration(milliseconds: 150));
        await confirm(h, confirmLabel);
        await h.pumpFor(const Duration(milliseconds: 800));
      }

      await h.untilFound(find.text('Not on GitHub'));
      await act('Verify API v2', 'Push', 'Push');
      await status('Verify API v2', 'Up to date');
      expect(
        fake.files.keys,
        contains('api-client/collections/verify-api-v2.json'),
      );
      expect(
        fake.files.values.map((f) => f.$2).join(),
        isNot(contains(bearerSecret)),
      );
      Harness.record('Sync: create (push new collection)');

      // Local update → push.
      final repo = gh.read(collectionRepositoryProvider);
      final tree = (await repo.watchTrees().first).firstWhere(
        (t) => t.collection.name == 'Verify API v2',
      );
      await repo.updateCollection(
        tree.collection.id,
        description: 'changed locally',
      );
      await h.tap(find.byTooltip('Refresh'));
      await status('Verify API v2', 'Local changes');
      await act('Verify API v2', 'Push', 'Push');
      await status('Verify API v2', 'Up to date');
      Harness.record('Sync: update (push local change)');

      // Remote update → pull (asks before overwriting local).
      const path = 'api-client/collections/verify-api-v2.json';
      fake.files[path] = (
        'remote1',
        fake.files[path]!.$2.replaceAll(
          'Health check',
          'Health check (remote)',
        ),
      );
      await h.tap(find.byTooltip('Refresh'));
      await status('Verify API v2', 'Changed on GitHub');
      await act('Verify API v2', 'Pull', 'Overwrite local');
      expect(
        (await repo.watchTrees().first)
            .expand((t) => t.allRequests)
            .any((r) => r.name == 'Health check (remote)'),
        isTrue,
      );
      Harness.record('Sync: pull remote change (with overwrite confirmation)');

      // Conflict: both sides changed; nothing is written without a choice.
      fake.files[path] = (
        'remote2',
        fake.files[path]!.$2.replaceAll('changed locally', 'changed remotely'),
      );
      await repo.updateCollection(
        tree.collection.id,
        description: 'changed again locally',
      );
      await h.tap(find.byTooltip('Refresh'));
      await status('Verify API v2', 'Conflict');
      expect(fake.files[path]!.$1, 'remote2', reason: 'no silent overwrite');
      await h.shot('15_sync_conflict');
      await act('Verify API v2', 'Keep local', 'Overwrite GitHub');
      expect(fake.files[path]!.$2, contains('changed again locally'));
      Harness.record('Sync: conflict detected, resolved explicitly');

      // Local deletion → shows as "Only on GitHub" → re-import.
      await repo.deleteCollection(tree.collection.id);
      await h.tap(find.byTooltip('Refresh'));
      await h.untilFound(find.text('Only on GitHub'));
      // The never-synced namesake (from test 11) stays "Not on GitHub"; the
      // deleted collection's file is offered for import.
      await h.tap(
        find.descendant(
          of: dialog,
          matching: find.widgetWithText(TextButton, 'Import'),
        ),
      );
      await confirm(h, 'Pull');
      await h.pumpFor(const Duration(milliseconds: 800));
      expect(
        (await repo.watchTrees().first).any(
          (t) => t.collection.name == 'Verify API v2',
        ),
        isTrue,
      );
      Harness.record('Sync: locally deleted collection recovered from GitHub');
      await h.tap(find.widgetWithText(TextButton, 'Close'));

      // Disconnect removes the token.
      await h.tap(find.text('Disconnect'));
      await confirm(h, 'Disconnect');
      await h.untilFound(find.text('Not connected'));
      expect(await Harness.keychainHas(VaultKeys.githubSession), isFalse);
      Harness.record(
        'GitHub disconnect',
        detail: 'token removed from Keychain',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  check('16 window sizes, themes, tabs, menus and shortcuts', (tester) async {
    final h = await start(tester);
    Future<void> tour(String prefix) async {
      for (final s in [
        'Params',
        'Authorization',
        'Headers',
        'Body',
        'Cookies',
        'Settings',
      ]) {
        await h.requestSection(s);
      }
      for (final t in ['Collections', 'Environments', 'History']) {
        await h.tap(find.byTooltip(t));
        await h.pumpFor(const Duration(milliseconds: 150));
      }
      await h.tap(find.byTooltip('Collections'));
      await h.shot('${prefix}_main');
      await h.tap(find.byTooltip('Settings (⌘,)'));
      for (final s in ['Network', 'Security', 'Accounts', 'Data', 'General']) {
        await h.tap(find.text(s));
      }
      await h.shot('${prefix}_settings');
      await h.tap(find.byTooltip('Settings (⌘,)'));
    }

    await h.newTab();
    await h.setUrl('$base/json?items=50');
    await h.send();

    // The minimum size is enforced by NSWindow.minSize for user resizing
    // (programmatic frames can go lower), so render exactly at the minimum.
    await windowManager.setSize(minimumWindowSize);
    await h.pumpFor(const Duration(milliseconds: 600));
    final min = await windowManager.getSize();
    expect(min.width, minimumWindowSize.width);
    await tour('16_min');
    Harness.record(
      'Minimum window size',
      detail:
          '${min.width.toInt()}x${min.height.toInt()}: every section rendered without overflow',
    );

    await windowManager.maximize();
    await h.pumpFor(const Duration(seconds: 1));
    final max = await windowManager.getSize();
    await tour('16_max');
    await windowManager.unmaximize();
    await windowManager.setSize(const Size(1440, 900));
    await h.pumpFor(const Duration(milliseconds: 600));
    Harness.record(
      'Maximized window',
      detail: '${max.width.toInt()}x${max.height.toInt()}; no overflow',
    );

    // Light theme through the Settings UI, then back to dark.
    await h.tap(find.byTooltip('Settings (⌘,)'));
    await h.tap(find.text('Light'));
    expect(h.settings.themeMode, ThemeMode.light);
    await h.tap(find.byTooltip('Settings (⌘,)'));
    await tour('16_light');
    await h.tap(find.byTooltip('Settings (⌘,)'));
    await h.tap(find.text('Dark'));
    await h.tap(find.byTooltip('Settings (⌘,)'));
    Harness.record(
      'Light and dark themes',
      detail: 'all sections rendered in both',
    );

    // Tabs via context menu.
    final count = h.ws.tabs.length;
    Finder activeTab() => find.descendant(
      of: find.byType(TabStrip),
      matching: find.byKey(ValueKey(h.tabId)),
    );
    await h.rightClick(activeTab());
    await h.tap(h.menuItem('Duplicate'));
    await h.until(() => h.ws.tabs.length == count + 1, what: 'duplicated tab');
    await h.rightClick(activeTab());
    await h.tap(h.menuItem('Close other tabs'));
    await h.until(() => h.ws.tabs.length == 1, what: 'close others');
    Harness.record('Tabs: new, duplicate, close, close others (context menu)');

    // Native macOS menu bar: registered items, shortcuts and handlers.
    final bar = tester.widget<PlatformMenuBar>(find.byType(PlatformMenuBar));
    final items = <String, PlatformMenuItem>{};
    void collect(List<PlatformMenuItem> list) {
      for (final i in list) {
        if (i is PlatformMenu) {
          collect(i.menus);
        } else if (i is PlatformMenuItemGroup) {
          collect(i.members);
        } else {
          items[i.label] = i;
        }
      }
    }

    collect(bar.menus);
    for (final label in [
      'New Tab',
      'Close Tab',
      'Save',
      'Send Request',
      'Settings…',
      'Toggle Sidebar',
      'Import cURL…',
    ]) {
      expect(items[label]?.shortcut, isNotNull, reason: label);
    }
    items['New Tab']!.onSelected!();
    await h.pumpFor(const Duration(milliseconds: 200));
    expect(h.ws.tabs.length, 2);
    items['Close Tab']!.onSelected!();
    await h.pumpFor(const Duration(milliseconds: 200));
    expect(h.ws.tabs.length, 1);
    items['Toggle Sidebar']!.onSelected!();
    await h.pumpFor(const Duration(milliseconds: 200));
    expect(find.byType(CollectionTreeView), findsNothing);
    items['Toggle Sidebar']!.onSelected!();
    await h.pumpFor(const Duration(milliseconds: 200));
    Harness.record(
      'macOS menu bar',
      detail:
          '${items.length} items registered with ⌘ shortcuts; handlers verified',
    );

    await h.shot('16_final');
  });
}
