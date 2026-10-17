import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/core/utils/shutdown.dart';

void main() {
  test('runs every step in order', () async {
    final ran = <int>[];
    final ok = await runShutdownSteps([
      () async => ran.add(1),
      () async => ran.add(2),
    ]);
    expect(ok, isTrue);
    expect(ran, [1, 2]);
  });

  test('a failing step does not stop the others', () async {
    final ran = <int>[];
    final errors = <Object>[];
    final ok = await runShutdownSteps([
      () async => throw StateError('log locked'),
      () async => ran.add(2),
    ], onError: errors.add);
    expect(ok, isTrue);
    expect(ran, [2]);
    expect(errors.single, isA<StateError>());
  });

  test('a stuck step cannot keep the app open', () async {
    final watch = Stopwatch()..start();
    final ok = await runShutdownSteps([
      () => Completer<void>().future, // e.g. a database that never closes
    ], timeout: const Duration(milliseconds: 200));
    expect(ok, isFalse);
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
  });
}
