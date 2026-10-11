import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/core/di/app_providers.dart';
import 'package:vesper/core/security/secret_vault.dart';
import 'package:vesper/core/storage/app_database.dart';
import 'package:vesper/core/theme/app_theme.dart';
import 'package:vesper/features/api_client/domain/models/api_request.dart';
import 'package:vesper/features/api_client/domain/models/http_method.dart';
import 'package:vesper/features/api_client/domain/models/request_auth.dart';
import 'package:vesper/features/api_client/domain/services/request_preparer.dart';
import 'package:vesper/features/api_client/domain/services/variable_resolver.dart';
import 'package:vesper/features/api_client/presentation/request/auth_editor.dart';
import 'package:vesper/features/api_client/presentation/request/code_snippet_dialog.dart';
import 'package:vesper/features/collections/presentation/collection_editor.dart';
import 'package:vesper/features/workspace/domain/workspace_models.dart';
import 'package:vesper/features/workspace/presentation/workspace_controller.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets('collection auth is edited, saved and shown to inheriting '
      'requests', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    final vault = InMemoryVault();
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        vaultProvider.overrideWithValue(vault),
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

    final repo = container.read(collectionRepositoryProvider);
    final (collection, request) = (await tester.runAsync(() async {
      final c = await repo.createCollection('Shop API');
      final r = await repo.saveRequest(
        ApiRequest(
          name: 'Orders',
          collectionId: c.id,
          auth: const InheritAuth(),
        ),
      );
      return (c, r);
    }))!;
    final tabs = container.read(workspaceProvider.notifier);
    await tester.runAsync(() => tabs.openSavedRequest(request.id));
    tabs.openCollection(collection.id, collection.name);
    final collectionTab = container.read(workspaceProvider).activeTab!;

    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                final active = ref.watch(workspaceProvider).activeTab;
                return active is CollectionTab
                    ? CollectionEditor(tabId: active.id)
                    : AuthEditor(tabId: active!.id);
              },
            ),
          ),
        ),
      ),
    );
    await settle();
    expect(find.text('Shop API'), findsOneWidget);

    // Choose Bearer Token and enter a token.
    await tester.tap(find.byType(DropdownButtonFormField<AuthType>));
    await settle();
    expect(
      find.text(AuthType.inherit.label),
      findsNothing,
      reason: 'a collection has no parent to inherit from',
    );
    await tester.tap(find.text(AuthType.bearer.label).last);
    await settle();
    await tester.enterText(find.byType(TextField).first, 'shop-token');
    await settle();
    await tester.tap(find.byKey(const ValueKey('save-collection')));
    await settle();
    final saved = await tester.runAsync(() => repo.getSettings(collection.id));
    expect(saved!.auth, const BearerAuth(token: 'shop-token'));

    // The request tab explains where its auth comes from.
    final requestTab = container
        .read(workspaceProvider)
        .tabs
        .firstWhere((t) => t.id != collectionTab.id);
    tabs.activate(requestTab.id);
    await settle();
    expect(
      find.textContaining('Bearer Token authorization of the "Shop API"'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('edit-collection-auth')));
    await settle();
    expect(container.read(workspaceProvider).activeTab!.id, collectionTab.id);
    await tester.pump(const Duration(seconds: 4)); // toast and tab persistence
  });

  testWidgets('code snippet dialog switches language and copies', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    final prepared = const RequestPreparer().prepare(
      ApiRequest(method: HttpMethod.delete, url: 'https://api.dev/items/1'),
      VariableResolver(),
    );
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(body: CodeSnippetDialog(request: prepared)),
        ),
      ),
    );
    expect(find.textContaining('curl'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('snippet-pythonRequests')));
    await tester.pumpAndSettle();
    expect(find.textContaining('import requests'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('copy-snippet')));
    await tester.pump();
    expect(copied, contains('requests.request("DELETE"'));
    await tester.pump(const Duration(seconds: 4));
  });
}
