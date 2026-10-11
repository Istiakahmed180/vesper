import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/core/di/app_providers.dart';
import 'package:vesper/core/security/secret_vault.dart';
import 'package:vesper/core/storage/app_database.dart';
import 'package:vesper/core/theme/app_theme.dart';
import 'package:vesper/features/environments/domain/environment_models.dart';
import 'package:vesper/features/environments/presentation/environment_providers.dart';
import 'package:vesper/features/environments/presentation/environment_quick_look.dart';
import 'package:vesper/features/workspaces/presentation/workspace_providers.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets('quick look shows, adds and edits variables', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        vaultProvider.overrideWithValue(InMemoryVault()),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await tester.runAsync(db.close);
    });
    Future<void> settle() async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pumpAndSettle();
    }

    // Set up the data before any stream starts in the fake-async zone.
    await tester.runAsync(() async {
      final env = await container
          .read(environmentRepositoryProvider)
          .createEnvironment(
            'Staging',
            variables: [EnvVariable(key: 'base_url', value: 'https://stg')],
          );
      await container
          .read(activeWorkspaceIdProvider.notifier)
          .setActiveEnvironment(env.id);
    });
    container
      ..listen(environmentsProvider, (_, _) {})
      ..listen(workspacesProvider, (_, _) {});

    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(
            body: Align(
              alignment: Alignment.topRight,
              child: EnvironmentQuickLook(),
            ),
          ),
        ),
      ),
    );
    await settle();
    await tester.tap(find.byKey(const ValueKey('environment-quick-look')));
    await settle();
    expect(find.text('Staging'), findsOneWidget);
    expect(find.text('Globals'), findsOneWidget);
    expect(find.text('base_url'), findsOneWidget);

    // Add a variable to the active environment (the first add row).
    await tester.enterText(
      find.byKey(const ValueKey('quick-new-key')).first,
      'user_id',
    );
    await tester.enterText(
      find.byKey(const ValueKey('quick-new-value')).first,
      '42',
    );
    await tester.tap(find.byKey(const ValueKey('quick-add')).first);
    await settle();

    // Edit an existing value in place.
    await tester.enterText(
      find.widgetWithText(TextField, 'https://stg'),
      'https://new',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle();

    final staging = container.read(activeEnvironmentProvider)!;
    expect(staging.variables.map((v) => (v.key, v.value)), [
      ('base_url', 'https://new'),
      ('user_id', '42'),
    ]);
    await tester.pump(const Duration(seconds: 4));
  });
}
