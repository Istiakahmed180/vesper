import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/core/di/app_providers.dart';
import 'package:vesper/core/security/secret_vault.dart';
import 'package:vesper/core/storage/app_database.dart';
import 'package:vesper/core/theme/app_theme.dart';
import 'package:vesper/features/api_client/domain/models/api_request.dart';
import 'package:vesper/features/collections/presentation/collection_tree_view.dart';
import 'package:vesper/features/workspace/domain/workspace_models.dart';
import 'package:vesper/features/workspace/presentation/workspace_controller.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets('collections and folders collapse and expand, even around the '
      'open request', (tester) async {
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

    await tester.runAsync(() async {
      final repo = container.read(collectionRepositoryProvider);
      final chat = await repo.createCollection('Chat API');
      final conversations = await repo.createFolder(chat.id, 'Conversations');
      await repo.createFolder(chat.id, 'Users');
      for (final name in ['List Conversations', 'Send Message']) {
        await repo.saveRequest(
          ApiRequest(
            name: name,
            collectionId: chat.id,
            folderId: conversations.id,
          ),
        );
      }
      await repo.createCollection('Cards API');
    });

    Future<void> settle() async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
    }

    Future<void> tapRow(String name) async {
      await tester.tap(find.text(name));
      await settle();
    }

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(
            body: SizedBox(
              width: 320,
              height: 600,
              child: CollectionTreeView(),
            ),
          ),
        ),
      ),
    );
    await settle();

    // Collapsed at first.
    expect(find.text('Conversations'), findsNothing);

    // Expand collection, then folder.
    await tapRow('Chat API');
    expect(find.text('Conversations'), findsOneWidget);
    expect(find.text('List Conversations'), findsNothing);
    await tapRow('Conversations');
    expect(find.text('List Conversations'), findsOneWidget);

    // Collapse and expand the folder again.
    await tapRow('Conversations');
    expect(find.text('List Conversations'), findsNothing);
    await tapRow('Conversations');
    expect(find.text('List Conversations'), findsOneWidget);

    // Open a request: its folder must still collapse and stay collapsed.
    await tapRow('Send Message');
    final ws = container.read(workspaceProvider);
    expect(ws.activeTab, isA<RequestTab>());
    await tapRow('Conversations');
    expect(find.text('Send Message'), findsNothing);

    // Editing the open request or a tree refresh does not reopen it.
    final tabId = container.read(workspaceProvider).activeTab!.id;
    container.read(workspaceProvider.notifier).setUrl(tabId, 'https://x.test');
    await settle();
    await tester.runAsync(
      () =>
          container.read(collectionRepositoryProvider).createCollection('New'),
    );
    await settle();
    expect(find.text('Send Message'), findsNothing);

    // The collection holding the open request collapses too.
    await tapRow('Chat API');
    expect(find.text('Conversations'), findsNothing);
    expect(find.text('Users'), findsNothing);
    await tapRow('Chat API');
    expect(find.text('Conversations'), findsOneWidget);
    expect(find.text('Send Message'), findsNothing);

    // Switching to another tab and back reveals the open request again.
    final notifier = container.read(workspaceProvider.notifier);
    final other = notifier.newRequestTab();
    await settle();
    notifier.activate(tabId);
    await settle();
    expect(find.text('Send Message'), findsOneWidget);
    expect(other, isNotEmpty);

    // Other collections are unaffected.
    await tapRow('Cards API');
    await tapRow('Cards API');
    expect(find.text('Conversations'), findsOneWidget);

    // Let the tab persistence timer finish.
    await tester.pump(const Duration(seconds: 5));
    await settle();
  });
}
