import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/core/di/app_providers.dart';
import 'package:vesper/core/theme/app_theme.dart';
import 'package:vesper/features/environments/domain/environment_models.dart';
import 'package:vesper/features/environments/domain/environment_repository.dart';
import 'package:vesper/features/environments/presentation/environment_editor.dart';
import 'package:vesper/features/environments/presentation/environment_providers.dart';

class _RecordingRepo implements EnvironmentRepository {
  Environment? saved;
  @override
  Future<void> saveEnvironment(Environment environment) async =>
      saved = environment;
  @override
  Stream<List<Environment>> watchEnvironments() => const Stream.empty();
  @override
  Future<Environment> createEnvironment(
    String name, {
    List<EnvVariable> variables = const [],
  }) => throw UnimplementedError();
  @override
  Future<void> deleteEnvironment(String id) => throw UnimplementedError();
  @override
  Future<Environment> duplicateEnvironment(String id) =>
      throw UnimplementedError();
}

void main() {
  testWidgets('adding several variables keeps every row and saves them', (
    tester,
  ) async {
    final env = Environment(id: 'e1', name: 'Local');
    final repo = _RecordingRepo();
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          environmentsProvider.overrideWith((ref) => Stream.value([env])),
          environmentRepositoryProvider.overrideWithValue(repo),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(body: EnvironmentEditor(environmentId: 'e1')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Text fields in on-screen order: [key, value] per row, trailing new row last.
    Finder field(int i) => find.byType(TextField).at(i);
    await tester.enterText(field(0), 'base_url');
    await tester.pump();
    await tester.enterText(field(1), 'http://localhost:8080');
    await tester.pump();
    await tester.enterText(field(2), 'token');
    await tester.pump();
    await tester.enterText(field(3), 'test-token');
    await tester.pump();
    await tester.tap(find.byType(Switch).at(1));
    await tester.pump();

    expect(find.byType(Switch), findsNWidgets(2));
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(repo.saved!.variables.map((v) => (v.key, v.value, v.isSecret)), [
      ('base_url', 'http://localhost:8080', false),
      ('token', 'test-token', true),
    ]);
  });
}
