import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/features/api_client/domain/services/fake_data.dart';
import 'package:vesper/features/api_client/domain/services/variable_resolver.dart';

void main() {
  final clock = DateTime.utc(2026, 1, 15, 12);

  test('every fake variable produces a value', () {
    final fake = FakeData(random: Random(1), clock: () => clock);
    for (final v in FakeData.variables) {
      expect(v.generate(fake), isNotEmpty, reason: v.name);
      expect(v.name, startsWith(r'$random'), reason: v.name);
      expect(FakeData.categories, contains(v.category), reason: v.name);
    }
    expect(
      FakeData.variables.map((v) => v.name).toSet(),
      hasLength(FakeData.variables.length),
    );
  });

  test('values look like what they claim to be', () {
    final fake = FakeData(random: Random(7), clock: () => clock);
    for (var i = 0; i < 50; i++) {
      expect(
        fake.generate(r'$randomEmail'),
        matches(RegExp(r'^[a-z]+\.[a-z]+\d+@[a-z]+\.com$')),
      );
      expect(
        fake.generate(r'$randomUUID'),
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      expect(
        fake.generate(r'$randomIP'),
        matches(RegExp(r'^\d{1,3}(\.\d{1,3}){3}$')),
      );
      expect(
        fake.generate(r'$randomPrice'),
        matches(RegExp(r'^\d+\.\d{2}$')),
      );
      expect(
        DateTime.parse(fake.generate(r'$randomDatePast')!).isBefore(clock),
        isTrue,
      );
      expect(
        DateTime.parse(fake.generate(r'$randomDateFuture')!).isAfter(clock),
        isTrue,
      );
      expect(fake.generate(r'$randomBoolean'), anyOf('true', 'false'));
    }
  });

  test('resolver fills fake variables with a new value on each use', () {
    final resolver = VariableResolver(random: Random(3), clock: () => clock);
    final first = resolver(r'{{$randomEmail}}');
    final second = resolver(r'{{$randomEmail}}');
    expect(first, contains('@'));
    expect(first, isNot(second));

    final both = resolver(r'{{$randomFirstName}}|{{$randomFirstName}}');
    expect(both.split('|'), hasLength(2));
  });

  test('unknown random names stay unresolved', () {
    final resolved = VariableResolver().resolve(r'{{$randomNope}}');
    expect(resolved.value, r'{{$randomNope}}');
    expect(resolved.unresolved, {r'$randomNope'});
  });

  test('fake variables are listed as dynamic variables', () {
    expect(VariableResolver.dynamicVariables, contains(r'$randomEmail'));
    expect(VariableResolver.dynamicVariables, contains(r'$guid'));
  });
}
