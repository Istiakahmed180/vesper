import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/core/theme/app_theme.dart';
import 'package:vesper/features/api_client/domain/services/variable_resolver.dart';
import 'package:vesper/features/environments/domain/environment_models.dart';
import 'package:vesper/features/environments/presentation/environment_providers.dart';
import 'package:vesper/shared/widgets/code/code_editor.dart';
import 'package:vesper/shared/widgets/variable_autocomplete.dart';
import 'package:vesper/shared/widgets/variable_field.dart';

final resolver = VariableResolver(
  environment: {
    'base_url': const VariableValue(
      'https://sandbox.example.com/api',
      VariableSource.environment,
    ),
    'token': const VariableValue(
      's3cret',
      VariableSource.environment,
      isSecret: true,
    ),
  },
  globals: {'tenant': const VariableValue('acme', VariableSource.global)},
);

Widget host(Widget child) => ProviderScope(
  overrides: [
    variableResolverProvider.overrideWithValue(resolver),
    activeEnvironmentProvider.overrideWithValue(Environment(name: 'Sandbox')),
  ],
  child: MaterialApp(
    theme: AppTheme.dark(),
    home: Scaffold(
      body: Padding(padding: const EdgeInsets.all(20), child: child),
    ),
  ),
);

void main() {
  group('VariableToken', () {
    test('detects an unfinished {{name at the cursor', () {
      expect(VariableToken.at('{{ba', 4)!.query, 'ba');
      expect(VariableToken.at('x/{{', 4)!.query, '');
      expect(VariableToken.at('{{base_url}}/x', 14), isNull);
      expect(VariableToken.at('{{a b', 5), isNull);
      expect(VariableToken.at('abc', 3), isNull);
    });

    test('completes and swallows an existing tail', () {
      final t = VariableToken.at('{{ba}}/users', 4)!;
      final v = t.complete('{{ba}}/users', 'base_url');
      expect(v.text, '{{base_url}}/users');
      expect(v.selection.baseOffset, '{{base_url}}'.length);
      final t2 = VariableToken.at('x {{to', 6)!;
      expect(t2.complete('x {{to', 'token').text, 'x {{token}}');
    });

    test('ranks prefix matches first and masks secrets', () {
      final all = variableSuggestions('', resolver, environmentName: 'Sandbox');
      expect(all.map((s) => s.name), ['base_url', 'tenant', 'token']);
      final url = variableSuggestions('', resolver, hideCredentials: true);
      expect(url.map((s) => s.name), ['base_url', 'tenant']);
      final typed = variableSuggestions('to', resolver, hideCredentials: true);
      expect(
        typed.single.name,
        'token',
        reason: 'shown once the name is typed',
      );
      final dynamic = variableSuggestions(r'$', resolver);
      expect(dynamic.map((s) => s.name), contains(r'$guid'));
      expect(dynamic.every((s) => s.name.startsWith(r'$')), isTrue);
      final t = variableSuggestions('t', resolver);
      expect(t.map((s) => s.name).take(2), ['tenant', 'token']);
      expect(t[1].preview, isNot(contains('s3cret')));
      expect(variableSuggestions('url', resolver).single.name, 'base_url');
    });
  });

  // Desktop behaviour (no touch selection handles over the list).
  final macOS = TargetPlatformVariant.only(TargetPlatform.macOS);

  testWidgets('typing {{ in a field suggests variables; Enter inserts', (
    tester,
  ) async {
    var value = '';
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (context, setState) => VariableField(
            value: value,
            onChanged: (v) => setState(() => value = v),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '{{');
    await tester.pumpAndSettle();
    expect(find.text('base_url'), findsOneWidget);
    expect(find.text('Sandbox'), findsWidgets);
    expect(find.text('s3cret'), findsNothing);

    await tester.enterText(find.byType(TextField), '{{ba');
    await tester.pumpAndSettle();
    expect(find.text('token'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(value, '{{base_url}}');
    expect(
      find.text('https://sandbox.example.com/api'),
      findsNothing,
      reason: 'list closed',
    );
  }, variant: macOS);

  testWidgets('arrow keys choose, Escape dismisses, click inserts', (
    tester,
  ) async {
    var value = '';
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (context, setState) => VariableField(
            value: value,
            onChanged: (v) => setState(() => value = v),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'Bearer {{t');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(value, 'Bearer {{token}}');

    await tester.enterText(find.byType(TextField), '{{');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('tenant'), findsNothing);

    await tester.enterText(find.byType(TextField), '{{te');
    await tester.pumpAndSettle();
    await tester.tap(find.text('tenant'));
    await tester.pumpAndSettle();
    expect(value, '{{tenant}}');
  }, variant: macOS);

  testWidgets('works inside the multi-line body editor', (tester) async {
    var value = '';
    await tester.pumpWidget(
      host(
        SizedBox(
          height: 300,
          child: StatefulBuilder(
            builder: (context, setState) => CodeEditor(
              value: value,
              onChanged: (v) => setState(() => value = v),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '{"auth": "{{to');
    await tester.pumpAndSettle();
    expect(find.text('token'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(value, '{"auth": "{{token}}');
  }, variant: macOS);
}
