import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/core/theme/app_theme.dart';
import 'package:vesper/features/api_client/domain/models/api_request.dart';
import 'package:vesper/features/api_client/domain/models/http_method.dart';
import 'package:vesper/features/api_client/domain/models/key_value.dart';
import 'package:vesper/features/api_client/domain/models/request_body.dart';
import 'package:vesper/features/api_client/domain/services/header_catalog.dart';
import 'package:vesper/features/api_client/domain/services/request_preparer.dart';
import 'package:vesper/features/api_client/domain/services/variable_resolver.dart';
import 'package:vesper/features/api_client/presentation/request/default_headers.dart';
import 'package:vesper/features/environments/presentation/environment_providers.dart';
import 'package:vesper/shared/widgets/key_value_editor.dart';
import 'package:vesper/shared/widgets/variable_autocomplete.dart';

void main() {
  group('default headers', () {
    test('switched-off defaults are not sent; user headers still are', () {
      final request = ApiRequest(
        method: HttpMethod.post,
        url: 'https://api.dev/x',
        body: const RequestBody(type: BodyType.json, text: '{}'),
        headers: [KeyValue(key: 'X-Trace', value: '1')],
        options: const RequestOptions(
          disabledDefaultHeaders: {'user-agent', 'content-type'},
        ),
      );
      final prepared = const RequestPreparer().prepare(
        request,
        VariableResolver(),
      );
      expect(prepared.hasHeader('User-Agent'), isFalse);
      expect(prepared.hasHeader('Content-Type'), isFalse);
      expect(prepared.hasHeader('Accept'), isTrue);
      expect(prepared.hasHeader('X-Trace'), isTrue);

      final restored = ApiRequest.fromJson(request.toJson());
      expect(restored.options.disabledDefaultHeaders, {
        'user-agent',
        'content-type',
      });
      expect(restored.sameContentAs(request), isTrue);
    });

    test('lists the headers a request sends', () {
      final get = defaultHeadersFor(
        resolvedUrl: 'https://api.dev:8443/x',
        body: const RequestBody(),
        hasBody: false,
      );
      expect(get.map((h) => h.name), [
        'Host',
        'User-Agent',
        'Accept',
        'Accept-Encoding',
        'Connection',
      ]);
      expect(get.first.value, 'api.dev:8443');
      final post = defaultHeadersFor(
        resolvedUrl: 'api.dev',
        body: const RequestBody(type: BodyType.json),
        hasBody: true,
      );
      expect(
        post.map((h) => h.name),
        containsAll(['Content-Type', 'Content-Length']),
      );
      expect(post.firstWhere((h) => h.name == 'Content-Type').optional, isTrue);
      expect(post.firstWhere((h) => h.name == 'Host').optional, isFalse);
    });
  });

  test('header catalog suggests names and values', () {
    final names = HeaderCatalog.names('cont').map((e) => e.$1).toList();
    expect(names.first, startsWith('Content-'));
    expect(names, contains('Content-Type'));
    expect(HeaderCatalog.names(''), isNotEmpty, reason: 'popular headers');
    expect(
      HeaderCatalog.names('content-type').map((e) => e.$1),
      isNot(contains('Content-Type')),
      reason: 'an exact match needs no suggestion',
    );
    expect(HeaderCatalog.valuesFor('content-type', 'json'), [
      'application/json',
    ]);
    expect(HeaderCatalog.valuesFor('X-Unknown', ''), isEmpty);
  });

  testWidgets('choosing a header name from the dropdown fills the row', (
    tester,
  ) async {
    var rows = <KeyValue>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          variableResolverProvider.overrideWithValue(VariableResolver()),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => KeyValueEditor(
                rows: rows,
                keyHint: 'Header',
                keySuggestions: (text) => [
                  for (final (name, d) in HeaderCatalog.names(text))
                    VariableSuggestion(name, '', d),
                ],
                valueSuggestions: (key, text) => [
                  for (final v in HeaderCatalog.valuesFor(key, text))
                    VariableSuggestion(v, '', ''),
                ],
                onChanged: (r) => setState(() => rows = r),
              ),
            ),
          ),
        ),
      ),
    );
    final keyField = find.byType(TextField).first;
    await tester.tap(keyField);
    await tester.enterText(keyField, 'cont');
    await tester.pumpAndSettle();
    expect(find.text('Content-Type'), findsOneWidget);
    await tester.tap(find.text('Content-Type'));
    await tester.pumpAndSettle();
    expect(rows.single.key, 'Content-Type');

    // The value column now suggests content types.
    final valueField = find.byType(TextField).at(1);
    await tester.tap(valueField);
    await tester.enterText(valueField, 'json');
    await tester.pumpAndSettle();
    await tester.tap(find.text('application/json'));
    await tester.pumpAndSettle();
    expect(rows.single.value, 'application/json');

    // The header checkbox switches every row off and on again.
    rows = [...rows, KeyValue(key: 'Accept', value: '*/*')];
    await tester.pumpWidget(tester.widget(find.byType(ProviderScope)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('all-rows-checkbox')));
    await tester.pumpAndSettle();
    expect(rows.every((r) => !r.enabled), isTrue);
    await tester.tap(find.byKey(const ValueKey('all-rows-checkbox')));
    await tester.pumpAndSettle();
    expect(rows.every((r) => r.enabled), isTrue);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
