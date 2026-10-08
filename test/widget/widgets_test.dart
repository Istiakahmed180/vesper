import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/core/di/app_providers.dart';
import 'package:vesper/core/errors/app_failure.dart';
import 'package:vesper/core/network/cancel_handle.dart';
import 'package:vesper/core/theme/app_theme.dart';
import 'package:vesper/features/api_client/domain/models/api_response.dart';
import 'package:vesper/features/api_client/domain/models/http_method.dart';
import 'package:vesper/features/api_client/domain/models/key_value.dart';
import 'package:vesper/features/api_client/domain/models/prepared_request.dart';
import 'package:vesper/features/api_client/domain/repositories/http_client_port.dart';
import 'package:vesper/features/api_client/domain/services/variable_resolver.dart';
import 'package:vesper/features/api_client/presentation/response/body_formatter.dart';
import 'package:vesper/features/api_client/presentation/response/response_panel.dart';
import 'package:vesper/features/environments/presentation/environment_providers.dart';
import 'package:vesper/features/history/domain/history_models.dart';
import 'package:vesper/features/history/domain/history_repository.dart';
import 'package:vesper/features/settings/domain/app_settings.dart';
import 'package:vesper/features/workspace/presentation/response_controller.dart';
import 'package:vesper/features/workspace/presentation/workspace_controller.dart';
import 'package:vesper/shared/widgets/code/code_view.dart';
import 'package:vesper/shared/widgets/key_value_editor.dart';

class FakeHttp implements HttpClientPort {
  Object? error;
  PreparedRequest? last;

  @override
  Future<ApiResponse> send(
    PreparedRequest request, {
    required NetworkSettings settings,
    CancelHandle? cancel,
  }) async {
    last = request;
    if (error != null) throw error!;
    return ApiResponse(
      statusCode: 201,
      statusMessage: 'Created',
      headers: const [MapEntry('content-type', 'application/json')],
      bodyBytes: Uint8List.fromList(utf8.encode('{"id":7,"tags":["a","b"]}')),
      duration: const Duration(milliseconds: 12),
      requestUrl: request.url,
      method: request.method,
    );
  }

  @override
  void dispose() {}
}

class MemoryHistory implements HistoryRepository {
  final entries = <HistoryEntry>[];
  @override
  Future<void> add(HistoryEntry entry) async => entries.add(entry);
  @override
  Future<void> clear() async => entries.clear();
  @override
  Future<void> delete(String id) async =>
      entries.removeWhere((e) => e.id == id);
  @override
  Future<HistoryEntry?> get(String id) async =>
      entries.where((e) => e.id == id).firstOrNull;
  @override
  Future<int> prune({
    required int retentionDays,
    required int maxEntries,
  }) async => 0;
  @override
  Stream<List<HistoryEntry>> watch({int limit = 500}) => Stream.value(entries);
}

Widget host(Widget child, {List<dynamic> overrides = const []}) =>
    ProviderScope(
      overrides: [
        variableResolverProvider.overrideWithValue(
          VariableResolver(
            environment: {
              'host': const VariableValue(
                'https://api.test',
                VariableSource.environment,
              ),
            },
          ),
        ),
        ...overrides.cast(),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(body: child),
      ),
    );

void main() {
  testWidgets(
    'KeyValueEditor adds rows from the trailing empty row and removes them',
    (tester) async {
      var rows = <KeyValue>[];
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (context, setState) => KeyValueEditor(
              rows: rows,
              onChanged: (r) => setState(() => rows = r),
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField).first, 'X-Trace');
      await tester.pump();
      expect(rows.single.key, 'X-Trace');
      expect(find.byType(Checkbox), findsOneWidget);

      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      expect(rows.single.enabled, isFalse);

      await tester.tap(find.byTooltip('Remove'));
      await tester.pump();
      expect(rows, isEmpty);
    },
  );

  testWidgets('KeyValueEditor bulk edit parses lines', (tester) async {
    var rows = <KeyValue>[];
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (context, setState) => KeyValueEditor(
            rows: rows,
            onChanged: (r) => setState(() => rows = r),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Bulk edit'));
    await tester.pump();
    await tester.enterText(
      find.byType(TextField),
      'Accept: application/json\n//X-Off: 1',
    );
    await tester.pump();
    expect(rows.map((r) => (r.key, r.value, r.enabled)), [
      ('Accept', 'application/json', true),
      ('X-Off', '1', false),
    ]);
  });

  testWidgets('CodeView folds JSON blocks and highlights search matches', (
    tester,
  ) async {
    final body = formatText(
      '{"a":{"b":1,"c":2},"d":[1,2,3]}',
      CodeLanguage.json,
    );
    final controller = CodeViewController(body);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      host(
        SizedBox(
          width: 600,
          height: 400,
          child: CodeView(controller: controller),
        ),
      ),
    );
    final total = controller.visible.length;
    expect(total, body.lines.length);

    controller.collapseAll();
    await tester.pump();
    expect(controller.visible.length, lessThan(total));
    expect(find.textContaining('lines', findRichText: true), findsWidgets);

    controller.search('"c"');
    await tester.pump();
    expect(controller.matches.length, 1);
    // Revealing the match expands its parent block.
    expect(controller.visible, contains(controller.matches.single.line));
  });

  testWidgets('ResponsePanel shows empty, success and failure states', (
    tester,
  ) async {
    final http = FakeHttp();
    final history = MemoryHistory();
    final container = ProviderContainer(
      overrides: [
        httpClientProvider.overrideWithValue(http),
        historyRepositoryProvider.overrideWithValue(history),
        variableResolverProvider.overrideWithValue(
          VariableResolver(
            environment: {
              'host': const VariableValue(
                'https://api.test',
                VariableSource.environment,
              ),
            },
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final tabId = container.read(workspaceProvider).activeTab!.id;
    container.read(workspaceProvider.notifier)
      ..setUrl(tabId, '{{host}}/items?page=2')
      ..updateDraft(tabId, (d) => d.copyWith(method: HttpMethod.post));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(body: ResponsePanel(tabId: tabId)),
        ),
      ),
    );
    expect(find.text('Send a request to see the response'), findsOneWidget);

    await container.read(responseProvider(tabId).notifier).send();
    await tester.pumpAndSettle();
    expect(http.last!.url, 'https://api.test/items?page=2');
    expect(find.text('201 Created'), findsOneWidget);
    expect(find.textContaining('"id"', findRichText: true), findsWidgets);
    expect(history.entries.single.statusCode, 201);

    http.error = const NetworkFailure(
      NetworkFailureKind.dnsFailure,
      'Could not resolve host "api.test".',
    );
    await container.read(responseProvider(tabId).notifier).send();
    await tester.pumpAndSettle();
    expect(find.text('Host not found'), findsOneWidget);
    expect(find.textContaining('Could not resolve host'), findsOneWidget);
    expect(history.entries.last.errorMessage, isNotNull);
  });

  testWidgets('invalid URLs never reach the network', (tester) async {
    final http = FakeHttp();
    final container = ProviderContainer(
      overrides: [
        httpClientProvider.overrideWithValue(http),
        historyRepositoryProvider.overrideWithValue(MemoryHistory()),
        variableResolverProvider.overrideWithValue(VariableResolver()),
      ],
    );
    addTearDown(container.dispose);
    final tabId = container.read(workspaceProvider).activeTab!.id;
    container.read(workspaceProvider.notifier).setUrl(tabId, '{{missing}}/x');
    await container.read(responseProvider(tabId).notifier).send();
    final state = container.read(responseProvider(tabId));
    expect(state, isA<ResponseFailure>());
    expect((state as ResponseFailure).failure.message, contains('{{missing}}'));
    expect(http.last, isNull);
  });
}
