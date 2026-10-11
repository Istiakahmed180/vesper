import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/core/di/app_providers.dart';
import 'package:vesper/core/errors/app_failure.dart';
import 'package:vesper/core/oauth/oauth2_client.dart';
import 'package:vesper/core/security/secret_vault.dart';
import 'package:vesper/core/theme/app_theme.dart';
import 'package:vesper/features/auth/domain/auth_models.dart';
import 'package:vesper/features/auth/presentation/account_menu.dart';
import 'package:vesper/features/auth/presentation/auth_providers.dart';
import 'package:vesper/features/github/domain/github_models.dart';
import 'package:vesper/features/github/presentation/github_providers.dart';
import 'package:vesper/features/settings/presentation/settings_view.dart';
import 'package:vesper/features/workspace/presentation/shell_state.dart';
import 'package:vesper/features/workspace/presentation/sidebar.dart';

const _google = AuthSession(
  account: UserAccount(
    id: '1',
    email: 'me@example.com',
    name: 'Me',
    provider: 'google',
  ),
  token: OAuth2Token(accessToken: 'g'),
);

const _github = GitHubSession(
  accessToken: 'h',
  account: GitHubAccount(
    login: 'octo',
    name: 'Octo',
    avatarUrl: '',
    htmlUrl: '',
  ),
);

class _SignedInGoogle extends AuthController {
  @override
  Future<AuthSession?> build() async => _google;
}

class _ConnectedGitHub extends GitHubController {
  @override
  Future<GitHubSession?> build() async => _github;
}

void main() {
  group('one account at a time', () {
    test('Google sign-in is refused while GitHub is connected', () async {
      final container = ProviderContainer(
        overrides: [
          vaultProvider.overrideWithValue(InMemoryVault()),
          githubSessionProvider.overrideWith(_ConnectedGitHub.new),
        ],
      );
      addTearDown(container.dispose);
      await expectLater(
        container.read(authSessionProvider.notifier).signIn(),
        throwsA(
          isA<ValidationFailure>().having(
            (f) => f.message,
            'message',
            contains('Disconnect GitHub'),
          ),
        ),
      );
    });

    test('GitHub connect is refused while signed in with Google', () async {
      final container = ProviderContainer(
        overrides: [
          vaultProvider.overrideWithValue(InMemoryVault()),
          authSessionProvider.overrideWith(_SignedInGoogle.new),
        ],
      );
      addTearDown(container.dispose);
      await expectLater(
        container.read(githubSessionProvider.notifier).startConnect(),
        throwsA(
          isA<ValidationFailure>().having(
            (f) => f.message,
            'message',
            contains('Sign out first'),
          ),
        ),
      );
    });

    testWidgets('the menu only offers sign-out for the signed-in account', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            vaultProvider.overrideWithValue(InMemoryVault()),
            authSessionProvider.overrideWith(_SignedInGoogle.new),
          ],
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomLeft,
                child: AccountMenuButton(onOpenSettings: () {}),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('account-button')));
      await tester.pumpAndSettle();
      expect(find.text('Me'), findsOneWidget);
      expect(find.byKey(const ValueKey('account-github')), findsNothing);
      expect(find.byKey(const ValueKey('account-sign-in')), findsNothing);
      expect(find.text('Sign out'), findsOneWidget);
    });
  });

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
