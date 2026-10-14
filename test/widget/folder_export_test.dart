import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/core/di/app_providers.dart';
import 'package:vesper/core/security/secret_vault.dart';
import 'package:vesper/core/storage/app_database.dart';
import 'package:vesper/core/theme/app_theme.dart';
import 'package:vesper/features/api_client/domain/models/api_request.dart';
import 'package:vesper/features/collections/presentation/collection_providers.dart';
import 'package:vesper/features/collections/presentation/collection_tree_view.dart';

/// Stands in for the native Save dialog and keeps what would be written.
class _FakePicker extends FilePickerPlatform {
  String? fileName;
  Uint8List? bytes;

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
    this.fileName = fileName;
    this.bytes = bytes;
    return Uri.file('/tmp/$fileName');
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets('a folder exports only its own requests as JSON', (tester) async {
    final picker = _FakePicker();
    final original = FilePickerPlatform.instance;
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = original);

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

    late String folderId;
    await tester.runAsync(() async {
      final repo = container.read(collectionRepositoryProvider);
      final chat = await repo.createCollection('Chat API');
      final conversations = await repo.createFolder(chat.id, 'Conversations');
      final users = await repo.createFolder(chat.id, 'Users');
      folderId = conversations.id;
      for (final name in ['List', 'Create', 'Delete']) {
        await repo.saveRequest(
          ApiRequest(
            name: name,
            url: '{{api_url}}/conversations',
            collectionId: chat.id,
            folderId: conversations.id,
          ),
        );
      }
      await repo.saveRequest(
        ApiRequest(name: 'Profile', collectionId: chat.id, folderId: users.id),
      );
      container.read(expandedNodesProvider.notifier).expand([chat.id]);
    });

    Future<void> settle() async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(
            body: SizedBox(width: 320, child: CollectionTreeView()),
          ),
        ),
      ),
    );
    await settle();
    expect(find.text('Conversations'), findsOneWidget);

    // Right-click the folder → Export… → Export… in the dialog.
    await tester.tap(find.text('Conversations'), buttons: kSecondaryButton);
    await settle();
    await tester.tap(find.byKey(const ValueKey('folder-export')));
    await settle();
    expect(find.text('Export folder'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Export…'));
    await settle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();

    expect(picker.fileName, 'conversations.vesper.json');
    final json = jsonDecode(utf8.decode(picker.bytes!)) as Map;
    final text = jsonEncode(json);
    expect(text, contains('"Conversations"'));
    for (final name in ['List', 'Create', 'Delete']) {
      expect(text, contains('"$name"'));
    }
    expect(text, isNot(contains('Profile')));
    expect(text, isNot(contains('Users')));
    expect(folderId, isNotEmpty);
  });
}
