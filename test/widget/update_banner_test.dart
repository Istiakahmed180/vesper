import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/core/theme/app_theme.dart';
import 'package:vesper/features/updates/data/update_service.dart';
import 'package:vesper/features/updates/domain/app_release.dart';
import 'package:vesper/features/updates/presentation/update_controller.dart';
import 'package:vesper/features/updates/presentation/update_widgets.dart';

class _StaticService extends UpdateService {
  _StaticService() : super(platform: UpdatePlatform.macos);

  @override
  Future<AppRelease?> latest() async => const AppRelease(
    version: '0.3.0',
    notes: '* Faster requests',
    pageUrl: '',
    assetName: 'Vesper-0.3.0-macOS.dmg',
    assetUrl: '',
    assetSize: 0,
  );
}

void main() {
  testWidgets('banner shows a new version and hides on Later', (tester) async {
    final c = ProviderContainer(
      overrides: [
        currentVersionProvider.overrideWithValue('0.2.0'),
        autoUpdateSupportedProvider.overrideWithValue(false),
        updateServiceProvider.overrideWithValue(_StaticService()),
      ],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(
            body: Column(children: [UpdateBanner(), UpdateSettingsStatus()]),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('update-banner')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('check-updates')));
    await tester.pump();
    expect(find.textContaining('0.3.0 is available'), findsNWidgets(2));
    expect(find.text('Update & restart'), findsNWidgets(2));

    await tester.tap(find.text('What\'s new').first);
    await tester.pumpAndSettle();
    // Notes are Markdown: the list marker becomes a bullet.
    expect(find.text('Faster requests'), findsOneWidget);
    expect(find.text('* Faster requests'), findsNothing);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Later'));
    await tester.pump();
    expect(find.byKey(const ValueKey('update-banner')), findsNothing);
  });
}
