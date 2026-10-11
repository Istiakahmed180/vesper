import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../github/presentation/github_connect_dialog.dart';
import '../../github/presentation/github_providers.dart';
import '../domain/auth_models.dart';
import 'account_card.dart';
import 'auth_providers.dart';

/// Activity-rail account button. Opens a menu with the Google account,
/// GitHub connection, sign-in/out and a link to the account settings.
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
    final session = ref.watch(authSessionProvider).value;
    final googleConfigured = ref.watch(authRepositoryProvider).isConfigured;
    final githubConfigured = ref.watch(appConfigProvider).isGitHubConfigured;
    final github = ref.watch(githubSessionProvider).value;
    final signingIn = _signingIn != null;

    return MenuAnchor(
      controller: _menu,
      alignmentOffset: const Offset(48, -8),
      style: const MenuStyle(minimumSize: WidgetStatePropertyAll(Size(280, 0))),
      menuChildren: [
        _Header(session: session, signingIn: signingIn),
        const Divider(height: 9),
        if (session == null && googleConfigured)
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
        if (githubConfigured)
          github == null
              ? MenuItemButton(
                  leadingIcon: const Icon(Icons.hub_outlined, size: 18),
                  onPressed: () => showGitHubConnectDialog(context),
                  child: const Text('Connect GitHub…'),
                )
              : MenuItemButton(
                  leadingIcon: Icon(
                    Icons.hub_outlined,
                    size: 18,
                    color: colors.success,
                  ),
                  onPressed: widget.onOpenSettings,
                  child: Text('GitHub · @${github.account.login}'),
                ),
        MenuItemButton(
          key: const ValueKey('account-settings'),
          leadingIcon: const Icon(Icons.manage_accounts_outlined, size: 18),
          onPressed: widget.onOpenSettings,
          child: const Text('Account settings…'),
        ),
        if (session != null) ...[
          const Divider(height: 9),
          MenuItemButton(
            leadingIcon: const Icon(Icons.logout, size: 18),
            onPressed: () =>
                confirmGoogleSignOut(context, ref, session.account.email),
            child: const Text('Sign out'),
          ),
        ],
      ],
      child: Tooltip(
        message: session == null ? 'Account' : session.account.email,
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
                : session == null
                ? Icon(
                    Icons.account_circle_outlined,
                    size: 22,
                    color: colors.textSecondary,
                  )
                : Avatar(
                    initials: session.account.initials,
                    url: session.account.pictureUrl,
                    size: 26,
                  ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.session, required this.signingIn});

  final AuthSession? session;
  final bool signingIn;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final s = session;
    final (title, subtitle) = s == null
        ? (
            'Not signed in',
            signingIn
                ? 'Complete sign-in in your browser…'
                : 'Vesper works fully offline without an account.',
          )
        : (
            s.account.name.isEmpty ? s.account.email : s.account.name,
            '${s.account.email}${s.offline ? ' · offline' : ''}',
          );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        child: Row(
          children: [
            if (s == null)
              Icon(
                Icons.account_circle_outlined,
                size: 34,
                color: colors.textMuted,
              )
            else
              Avatar(
                initials: s.account.initials,
                url: s.account.pictureUrl,
                size: 34,
              ),
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
