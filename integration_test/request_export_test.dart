import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:file_picker/file_picker.dart';
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
import 'package:vesper/features/api_client/domain/models/key_value.dart';
import 'package:vesper/features/collections/presentation/collection_tree_view.dart';
import 'package:vesper/features/import_export/domain/import_service.dart';
import 'package:vesper/features/workspace/presentation/workspace_controller.dart';

/// Runs the real app on macOS and exports one request, from the sidebar
/// menu and from the request's ⋯ menu:
///   flutter test integration_test/request_export_test.dart -d macos \
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

/// Stands in for the native Save panel; keeps what would be written.
class _FakePicker extends FilePickerPlatform {
  final saved = <String, Uint8List>{};

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    saved[fileName] = bytes;
    if (shotDir.isNotEmpty) {
      await File('$shotDir/$fileName').writeAsBytes(bytes);
    }
    return Uri.file('/tmp/$fileName');
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('exports just the selected request as JSON', (tester) async {
    final picker = _FakePicker();
    FilePickerPlatform.instance = picker;

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
    final chat = await repo.createCollection('Chat API');
    final conversations = await repo.createFolder(chat.id, 'Conversations');
    await repo.createFolder(chat.id, 'Users');
    await repo.saveRequest(
      ApiRequest(
        name: 'List Conversations',
        url: '{{api_url}}/api/chat?status=active&per_page=15',
        params: [
          KeyValue(key: 'status', value: 'active'),
          KeyValue(key: 'per_page', value: '15'),
        ],
        collectionId: chat.id,
        folderId: conversations.id,
      ),
    );
    for (final name in ['Show Conversation', 'Send Message']) {
      await repo.saveRequest(
        ApiRequest(
          name: name,
          method: name.startsWith('Send') ? HttpMethod.post : HttpMethod.get,
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

    Finder row(String name) => find.descendant(
      of: find.byType(CollectionTreeView),
      matching: find.text(name),
    );

    Future<void> confirmExport() async {
      expect(find.text('Export request'), findsOneWidget);
      await shot(tester, 'export_dialog');
      await tester.tap(find.widgetWithText(FilledButton, 'Export…'));
      await settle();
      await settle();
    }

    /// The file holds exactly one request with this name and URL.
    void expectOnlyListConversations(Uint8List bytes) {
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
      final doc = const ImportService().parseCollection(json).value;
      final text = utf8.decode(bytes);
      expect(doc.name, 'List Conversations');
      expect(doc.items, hasLength(1));
      expect(text, contains('/api/chat?status=active&per_page=15'));
      expect(text, isNot(contains('Show Conversation')));
      expect(text, isNot(contains('Send Message')));
    }

    await settle();
    await tester.tap(row('Chat API'));
    await settle();
    await tester.tap(row('Conversations'));
    await settle();
    await tester.tap(row('List Conversations'));
    await settle();
    await shot(tester, 'r01_selected');

    // 1. Sidebar: right-click the request → Export…
    await tester.tap(row('List Conversations'), buttons: kSecondaryButton);
    await settle();
    await shot(tester, 'r02_sidebar_menu');
    await tester.tap(find.byKey(const ValueKey('request-export')));
    await settle();
    await confirmExport();
    expect(picker.saved.keys, ['list-conversations.vesper.json']);
    expectOnlyListConversations(picker.saved.values.single);

    // 2. The ⋯ menu next to Save.
    picker.saved.clear();
    await tester.tap(find.byTooltip('More'));
    await settle();
    await shot(tester, 'r03_more_menu');
    await tester.tap(find.byKey(const ValueKey('export-open-request')));
    await settle();
    await confirmExport();
    expect(picker.saved.keys, ['list-conversations.vesper.json']);
    expectOnlyListConversations(picker.saved.values.single);

    // 3. Unsaved edits: asks to save first instead of exporting old data.
    picker.saved.clear();
    final tabId = container.read(workspaceProvider).activeTab!.id;
    container
        .read(workspaceProvider.notifier)
        .setUrl(tabId, '{{api_url}}/api/chat?status=closed');
    await settle();
    await tester.tap(find.byTooltip('More'));
    await settle();
    await tester.tap(find.byKey(const ValueKey('export-open-request')));
    await settle();
    expect(find.textContaining('Save the request first'), findsOneWidget);
    expect(picker.saved, isEmpty);
    await shot(tester, 'r04_unsaved');

    await tester.pump(const Duration(seconds: 6));
  });
}
