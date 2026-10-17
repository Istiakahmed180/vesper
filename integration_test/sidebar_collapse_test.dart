import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vesper/app.dart';
import 'package:vesper/core/di/app_providers.dart';
import 'package:vesper/core/security/secret_vault.dart';
import 'package:vesper/core/storage/app_database.dart';
import 'package:vesper/features/api_client/domain/models/api_request.dart';
import 'package:vesper/features/api_client/domain/models/http_method.dart';
import 'package:vesper/features/collections/presentation/collection_tree_view.dart';
import 'package:vesper/features/workspace/presentation/workspace_controller.dart';

/// Runs the real app on macOS and clicks through the sidebar tree:
///   flutter test integration_test/sidebar_collapse_test.dart -d macos \
///     --dart-define=SHOT_DIR=/tmp/shots
const shotDir = String.fromEnvironment('SHOT_DIR');
final _boundary = GlobalKey();

Future<void> shot(WidgetTester tester, String name) async {
  if (shotDir.isEmpty) return;
  await tester.pump(const Duration(milliseconds: 200));
  final boundary =
      _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 1.5);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  await File('$shotDir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sidebar collections and folders collapse and expand', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        vaultProvider.overrideWithValue(InMemoryVault()),
      ],
      retry: (_, _) => null,
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });

    final repo = container.read(collectionRepositoryProvider);
    final supplier = await repo.createCollection('Business Supplier API');
    final linking = await repo.createFolder(supplier.id, 'CABEX Linking');
    await repo.createFolder(supplier.id, 'Suppliers');
    for (final (method, name) in [
      (HttpMethod.get, 'Search CABEX Users'),
      (HttpMethod.post, 'Link CABEX User'),
    ]) {
      await repo.saveRequest(
        ApiRequest(
          name: name,
          method: method,
          collectionId: supplier.id,
          folderId: linking.id,
        ),
      );
    }
    final chat = await repo.createCollection('Chat API');
    final conversations = await repo.createFolder(chat.id, 'Conversations');
    await repo.createFolder(chat.id, 'Users');
    for (final (method, name) in [
      (HttpMethod.get, 'List Conversations'),
      (HttpMethod.post, 'Send Message'),
    ]) {
      await repo.saveRequest(
        ApiRequest(
          name: name,
          method: method,
          collectionId: chat.id,
          folderId: conversations.id,
        ),
      );
    }

    await tester.binding.setSurfaceSize(const Size(1440, 900));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(key: _boundary, child: const VesperApp()),
      ),
    );

    Future<void> settle() async {
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
    }

    // Only rows of the sidebar tree (the breadcrumb and tabs repeat names).
    Finder row(String name) => find.descendant(
      of: find.byType(CollectionTreeView),
      matching: find.text(name),
    );

    Future<void> click(String name) async {
      await tester.tap(row(name));
      await settle();
    }

    bool shown(String name) => row(name).evaluate().isNotEmpty;

    await settle();
    await shot(tester, '01_start');
    expect(shown('Business Supplier API'), isTrue);
    expect(shown('Conversations'), isFalse);

    // Expand and collapse a collection and a folder.
    await click('Business Supplier API');
    expect(shown('CABEX Linking'), isTrue);
    await click('CABEX Linking');
    expect(shown('Link CABEX User'), isTrue);
    await shot(tester, '02_supplier_open');
    await click('CABEX Linking');
    expect(shown('Link CABEX User'), isFalse);
    await click('Business Supplier API');
    expect(shown('CABEX Linking'), isFalse);
    await shot(tester, '03_supplier_closed');

    // Open a request, then collapse its own folder and collection.
    await click('Chat API');
    await click('Conversations');
    await click('Send Message');
    expect(container.read(workspaceProvider).activeTab?.title, 'Send Message');
    await shot(tester, '04_request_open');

    await click('Conversations');
    expect(shown('List Conversations'), isFalse);
    await shot(tester, '05_folder_closed_with_open_request');

    // Typing in the open request does not reopen the folder.
    final tabId = container.read(workspaceProvider).activeTab!.id;
    container
        .read(workspaceProvider.notifier)
        .setUrl(tabId, 'https://sandbox.example.test/chat');
    await settle();
    expect(shown('List Conversations'), isFalse);

    await click('Chat API');
    expect(shown('Conversations'), isFalse);
    await shot(tester, '06_collection_closed_with_open_request');

    await click('Chat API');
    expect(shown('Conversations'), isTrue);
    expect(shown('List Conversations'), isFalse);
    await click('Conversations');
    expect(shown('List Conversations'), isTrue);
    await shot(tester, '07_reopened');

    // Mouse clicks that move a few pixels (as on Windows) still toggle.
    Future<void> shakyClick(String name) async {
      final gesture = await tester.startGesture(
        tester.getCenter(row(name)),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(2, 1));
      await gesture.moveBy(const Offset(1, 3));
      await gesture.up();
      await settle();
    }

    await shakyClick('Business Supplier API');
    expect(shown('CABEX Linking'), isTrue);
    await shakyClick('CABEX Linking');
    expect(shown('Link CABEX User'), isTrue);
    await shakyClick('CABEX Linking');
    expect(shown('Link CABEX User'), isFalse);
    await shakyClick('Business Supplier API');
    expect(shown('CABEX Linking'), isFalse);
    await shakyClick('Chat API');
    expect(shown('Conversations'), isFalse);
    await shot(tester, '08_shaky_clicks');

    await tester.pump(const Duration(seconds: 3));
  });
}
