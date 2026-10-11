import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../github/presentation/github_card.dart';
import '../../github/presentation/github_connect_dialog.dart';
import '../../github/presentation/github_providers.dart';
import 'account_card.dart';
import 'auth_providers.dart';

/// Activity-rail account button. Opens a menu with the signed-in account
/// (Google or GitHub, one at a time), sign-in/out and the account settings.
class AccountMenuButton extends ConsumerStatefulWidget {
  const AccountMenuButton({super.key, required this.onOpenSettings});

  /// Shows the Accounts page of Settings, where both accounts are managed.
  final VoidCallback onOpenSettings;

  @override
  ConsumerState<AccountMenuButton> createState() => _AccountMenuButtonState();
}

class _AccountMenuButtonState extends ConsumerState<AccountMenuButton> {
  final _menu = MenuController();
  Completer<void>? _signingIn;

  Future<void> _signIn() async {
    final cancel = Completer<void>();
    setState(() => _signingIn = cancel);
    await signInWithGoogle(context, ref, cancel.future);
    if (mounted) setState(() => _signingIn = null);
  }

  void _cancelSignIn() {
    final pending = _signingIn;
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final google = ref.watch(authSessionProvider).value;
    final github = ref.watch(githubSessionProvider).value;
    final googleConfigured = ref.watch(authRepositoryProvider).isConfigured;
    final githubConfigured = ref.watch(appConfigProvider).isGitHubConfigured;
    final signingIn = _signingIn != null;
    final signedIn = google != null || github != null;

    final (title, subtitle, Widget avatar) = switch ((google, github)) {
      (final g?, _) => (
        g.account.name.isEmpty ? g.account.email : g.account.name,
        '${g.account.email}${g.offline ? ' · offline' : ''} · Google',
        Avatar(
          initials: g.account.initials,
          url: g.account.pictureUrl,
          size: 34,
        ),
      ),
      (null, final h?) => (
        h.account.name.isEmpty ? '@${h.account.login}' : h.account.name,
        '@${h.account.login} · GitHub',
        Avatar(
          initials: h.account.login.isEmpty
              ? '?'
              : h.account.login[0].toUpperCase(),
          url: h.account.avatarUrl,
          size: 34,
        ),
      ),
      _ => (
        'Not signed in',
        signingIn
            ? 'Complete sign-in in your browser…'
            : 'Vesper works fully offline without an account.',
        Icon(Icons.account_circle_outlined, size: 34, color: colors.textMuted),
      ),
    };

    return MenuAnchor(
      controller: _menu,
      alignmentOffset: const Offset(48, -8),
      style: const MenuStyle(minimumSize: WidgetStatePropertyAll(Size(280, 0))),
      menuChildren: [
        _Header(avatar: avatar, title: title, subtitle: subtitle),
        const Divider(height: 9),
        // One account at a time: sign-in options only while signed out.
        if (!signedIn) ...[
          if (googleConfigured)
            signingIn
                ? MenuItemButton(
                    leadingIcon: const Icon(Icons.close, size: 18),
                    onPressed: _cancelSignIn,
                    child: const Text('Cancel sign-in'),
                  )
                : MenuItemButton(
                    key: const ValueKey('account-sign-in'),
                    leadingIcon: const Icon(Icons.login, size: 18),
                    onPressed: _signIn,
                    child: const Text('Sign in with Google'),
                  ),
          if (githubConfigured && !signingIn)
            MenuItemButton(
              key: const ValueKey('account-github'),
              leadingIcon: const Icon(Icons.hub_outlined, size: 18),
              onPressed: () => showGitHubConnectDialog(context),
              child: const Text('Sign in with GitHub…'),
            ),
        ],
        MenuItemButton(
          key: const ValueKey('account-settings'),
          leadingIcon: const Icon(Icons.manage_accounts_outlined, size: 18),
          onPressed: widget.onOpenSettings,
          child: const Text('Account settings…'),
        ),
        if (signedIn) ...[
          const Divider(height: 9),
          MenuItemButton(
            key: const ValueKey('account-sign-out'),
            leadingIcon: const Icon(Icons.logout, size: 18),
            onPressed: () => google != null
                ? confirmGoogleSignOut(context, ref, google.account.email)
                : confirmGitHubDisconnect(context, ref),
            child: Text(google != null ? 'Sign out' : 'Disconnect GitHub'),
          ),
        ],
      ],
      child: Tooltip(
        message: signedIn ? subtitle : 'Account',
        preferBelow: false,
        child: InkWell(
          key: const ValueKey('account-button'),
          borderRadius: BorderRadius.circular(20),
          onTap: () => _menu.isOpen ? _menu.close() : _menu.open(),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: signingIn
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: Padding(
                      padding: EdgeInsets.all(3),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : signedIn
                ? SizedBox(
                    width: 26,
                    height: 26,
                    child: FittedBox(child: avatar),
                  )
                : Icon(
                    Icons.account_circle_outlined,
                    size: 22,
                    color: colors.textSecondary,
                  ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.avatar,
    required this.title,
    required this.subtitle,
  });

  final Widget avatar;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        child: Row(
          children: [
            avatar,
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                    style: TextStyle(fontSize: 11.5, color: colors.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
