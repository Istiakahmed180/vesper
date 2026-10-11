import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/core/di/app_providers.dart';
import 'package:vesper/core/security/secret_vault.dart';
import 'package:vesper/core/theme/app_theme.dart';
import 'package:vesper/features/auth/presentation/account_menu.dart';
import 'package:vesper/features/settings/presentation/settings_view.dart';
import 'package:vesper/features/workspace/presentation/shell_state.dart';
import 'package:vesper/features/workspace/presentation/sidebar.dart';

void main() {
  testWidgets('the account button opens a menu instead of Settings', (
    tester,
  ) async {
    var settingsOpened = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [vaultProvider.overrideWithValue(InMemoryVault())],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomLeft,
              child: AccountMenuButton(onOpenSettings: () => settingsOpened++),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('account-button')));
    await tester.pumpAndSettle();
    expect(settingsOpened, 0);
    expect(find.text('Not signed in'), findsOneWidget);
    expect(find.text('Account settings…'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('account-settings')));
    await tester.pumpAndSettle();
    expect(settingsOpened, 1);
    expect(find.text('Not signed in'), findsNothing, reason: 'menu closed');
  });

  testWidgets('Account settings opens Settings on the Accounts page', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [vaultProvider.overrideWithValue(InMemoryVault())],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(body: Row(children: [ActivityRail(), Spacer()])),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('account-button')));
    await tester.pumpAndSettle();
    expect(container.read(shellProvider).section, ShellSection.collections);
    await tester.tap(find.byKey(const ValueKey('account-settings')));
    await tester.pumpAndSettle();
    expect(container.read(shellProvider).section, ShellSection.settings);
    expect(container.read(settingsPageProvider), SettingsPage.accounts);

    // Choosing it again while Settings is open keeps Settings open.
    await tester.tap(find.byKey(const ValueKey('account-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('account-settings')));
    await tester.pumpAndSettle();
    expect(container.read(shellProvider).section, ShellSection.settings);
  });
}
