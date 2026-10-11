import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/core/di/app_providers.dart';
import 'package:vesper/core/security/secret_vault.dart';
import 'package:vesper/core/storage/app_database.dart';
import 'package:vesper/core/theme/app_theme.dart';
import 'package:vesper/features/workspaces/presentation/workspace_providers.dart';
import 'package:vesper/features/workspaces/presentation/workspace_switcher.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets('switches, creates and renames workspaces from the menu', (
    tester,
  ) async {
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
    await tester.runAsync(
      () => container.read(workspaceRepositoryProvider).create('Client A'),
    );

    Future<void> settle() async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 260, child: WorkspaceSwitcher()),
            ),
          ),
        ),
      ),
    );
    await settle();
    expect(find.text(defaultWorkspaceName), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('workspace-switcher')));
    await settle();
    expect(find.text('Client A'), findsOneWidget);
    expect(
      find.text('Delete workspace…'),
      findsNothing,
      reason: 'the default workspace cannot be deleted',
    );
    expect(find.text('Share workspace…'), findsNothing);
    await tester.tap(find.text('Client A'));
    await settle();
    expect(container.read(activeWorkspaceProvider)?.name, 'Client A');

    // Only workspaces other than My Workspace can be shared, and sharing
    // needs a signed-in account.
    await tester.tap(find.byKey(const ValueKey('workspace-switcher')));
    await settle();
    await tester.tap(find.text('Share workspace…'));
    await settle();
    expect(
      find.textContaining('Sign in with Google or GitHub'),
      findsOneWidget,
    );
    await tester.tap(find.text('Done'));
    await settle();

    await tester.tap(find.byKey(const ValueKey('workspace-switcher')));
    await settle();
    expect(find.text('Delete workspace…'), findsOneWidget);
    await tester.tap(find.text('New workspace…'));
    await settle();
    await tester.enterText(find.byType(TextField), 'Staging');
    await tester.tap(find.text('Create'));
    await settle();
    expect(container.read(activeWorkspaceProvider)?.name, 'Staging');
    expect(find.text('Staging'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('workspace-switcher')));
    await settle();
    await tester.tap(find.text('Rename workspace…'));
    await settle();
    await tester.enterText(find.byType(TextField), 'QA');
    await tester.tap(find.text('Rename'));
    await settle();
    expect(container.read(activeWorkspaceProvider)?.name, 'QA');
  });
}
