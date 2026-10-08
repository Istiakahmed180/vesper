import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/core/di/app_providers.dart';
import 'package:vesper/core/storage/app_database.dart';
import 'package:vesper/core/theme/app_theme.dart';
import 'package:vesper/features/api_client/domain/models/api_request.dart';
import 'package:vesper/features/collections/domain/collection_models.dart';
import 'package:vesper/features/collections/presentation/collection_providers.dart';
import 'package:vesper/features/environments/domain/environment_models.dart';
import 'package:vesper/features/environments/presentation/environment_providers.dart';
import 'package:vesper/features/workspace/presentation/tab_strip.dart';
import 'package:vesper/features/workspace/presentation/workspace_controller.dart';

void main() {
  testWidgets('right-clicking a tab opens its context menu', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        environmentsProvider.overrideWith(
          (ref) => Stream.value(<Environment>[]),
        ),
        collectionTreesProvider.overrideWith(
          (ref) => Stream.value(<CollectionTree>[]),
        ),
      ],
    );
    addTearDown(container.dispose);
    container
        .read(workspaceProvider.notifier)
        .newRequestTab(ApiRequest(name: 'Second'));
    await tester.binding.setSurfaceSize(const Size(1200, 300));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(body: TabStrip()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final activeId = container.read(workspaceProvider).activeTab!.id;
    await tester.tap(find.byKey(ValueKey(activeId)), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('Duplicate'), findsOneWidget);

    await tester.tap(find.text('Duplicate'));
    await tester.pumpAndSettle();
    expect(container.read(workspaceProvider).tabs.length, 3);
    // Let the debounced workspace persistence finish.
    await tester.pump(const Duration(seconds: 1));
  });
}
