import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/features/api_client/domain/services/variable_resolver.dart';

VariableValue env(String v) => VariableValue(v, VariableSource.environment);
VariableValue glob(String v) => VariableValue(v, VariableSource.global);

void main() {
  group('VariableResolver', () {
    test('resolves environment variables', () {
      final r = VariableResolver(
        environment: {'base_url': env('https://api.example.com')},
      );
      final result = r.resolve('{{base_url}}/users');
      expect(result.value, 'https://api.example.com/users');
      expect(result.unresolved, isEmpty);
    });

    test('environment overrides globals', () {
      final r = VariableResolver(
        environment: {'token': env('env-token')},
        globals: {'token': glob('global-token'), 'other': glob('g')},
      );
      expect(r('{{token}} {{other}}'), 'env-token g');
    });

    test('tolerates whitespace inside braces', () {
      final r = VariableResolver(environment: {'id': env('42')});
      expect(r('/users/{{ id }}'), '/users/42');
    });

    test('reports unresolved variables and leaves them intact', () {
      final r = VariableResolver();
      final result = r.resolve('{{missing}}/x');
      expect(result.value, '{{missing}}/x');
      expect(result.unresolved, {'missing'});
    });

    test('resolves nested references', () {
      final r = VariableResolver(
        environment: {
          'host': env('api.example.com'),
          'base_url': env('https://{{host}}/v1'),
        },
      );
      expect(r('{{base_url}}/me'), 'https://api.example.com/v1/me');
    });

    test('does not loop forever on cycles', () {
      final r = VariableResolver(
        environment: {'a': env('{{b}}'), 'b': env('{{a}}')},
      );
      expect(() => r.resolve('{{a}}'), returnsNormally);
    });

    test('supports dynamic variables', () {
      final r = VariableResolver(
        random: Random(1),
        clock: () => DateTime.utc(2024, 1, 1),
      );
      expect(r(r'{{$timestamp}}'), '1704067200');
      expect(r(r'{{$isoTimestamp}}'), '2024-01-01T00:00:00.000Z');
      expect(r(r'{{$guid}}'), matches(RegExp(r'^[0-9a-f-]{36}$')));
      expect(int.parse(r(r'{{$randomInt}}')), inInclusiveRange(0, 1000));
    });

    test('lists referenced names', () {
      expect(VariableResolver.referencedNames('{{a}}/x/{{ b }}'), ['a', 'b']);
    });
  });
}
