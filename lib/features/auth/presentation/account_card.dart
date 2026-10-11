import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/dialogs.dart';
import '../../github/presentation/github_providers.dart';
import '../domain/auth_models.dart';
import 'auth_providers.dart';

class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.initials, this.url, this.size = 32});
  final String initials;
  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.accentMuted,
        shape: BoxShape.circle,
      ),
      child: Text(
        initials,
        style: TextStyle(
          fontSize: size * 0.38,
          color: colors.accent,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
    if (url == null || url!.isEmpty) return fallback;
    return ClipOval(
      child: Image.network(
        url!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }
}

/// Runs Google sign-in in the browser and reports the outcome as a toast.
/// Completing [cancelled] abandons a sign-in that is still waiting.
Future<void> signInWithGoogle(
  BuildContext context,
  WidgetRef ref,
  Future<void> cancelled,
) async {
  try {
    await ref.read(authSessionProvider.notifier).signIn(cancelled: cancelled);
    if (context.mounted) showToast(context, 'Signed in');
  } on AuthFailure catch (f) {
    if (context.mounted && f.kind != AuthFailureKind.cancelled) {
      showToast(context, f.message, error: true);
    }
  } catch (e) {
    if (context.mounted) showToast(context, e.userMessage, error: true);
  }
}

/// Asks for confirmation, then signs out of Google.
Future<void> confirmGoogleSignOut(
  BuildContext context,
  WidgetRef ref,
  String email,
) async {
  final ok = await confirmDialog(
    context,
    title: 'Sign out',
    message:
        'Sign out of $email? Your local collections stay on this computer.',
    confirmLabel: 'Sign out',
    destructive: false,
  );
  if (ok) await ref.read(authSessionProvider.notifier).signOut();
}

/// Google account status, sign-in and sign-out.
class AccountCard extends ConsumerStatefulWidget {
  const AccountCard({super.key});

  @override
  ConsumerState<AccountCard> createState() => _AccountCardState();
}

class _AccountCardState extends ConsumerState<AccountCard> {
  Completer<void>? _cancel;

  Future<void> _signIn() async {
    final cancel = Completer<void>();
    setState(() => _cancel = cancel);
    await signInWithGoogle(context, ref, cancel.future);
    if (mounted) setState(() => _cancel = null);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final configured = ref.watch(authRepositoryProvider).isConfigured;
    final session = ref.watch(authSessionProvider);

    Widget content;
    if (!configured) {
      content = _row(
        icon: Icon(Icons.info_outline, color: colors.textMuted),
        title: 'Google sign-in is not configured',
        subtitle:
            'Provide GOOGLE_CLIENT_ID at build time (see docs/authentication.md). Vesper works fully offline without an account.',
      );
    } else if (session.isLoading) {
      content = const Padding(
        padding: EdgeInsets.all(16),
        child: LinearProgressIndicator(),
      );
    } else if (session.value case final AuthSession s) {
      content = _row(
        icon: Avatar(
          initials: s.account.initials,
          url: s.account.pictureUrl,
          size: 36,
        ),
        title: s.account.name.isEmpty ? s.account.email : s.account.name,
        subtitle: '${s.account.email}${s.offline ? ' · offline' : ''} · Google',
        trailing: OutlinedButton(
          onPressed: () => confirmGoogleSignOut(context, ref, s.account.email),
          child: const Text('Sign out'),
        ),
      );
    } else if (ref.watch(githubSessionProvider).value case final github?) {
      content = _row(
        icon: Icon(Icons.hub_outlined, size: 32, color: colors.textMuted),
        title: 'Signed in with GitHub (@${github.account.login})',
        subtitle:
            'Only one account can be used at a time. Disconnect GitHub to '
            'sign in with Google.',
        trailing: const FilledButton(
          onPressed: null,
          child: Text('Sign in with Google'),
        ),
      );
    } else {
      content = _row(
        icon: Icon(
          Icons.account_circle_outlined,
          size: 32,
          color: colors.textMuted,
        ),
        title: 'Not signed in',
        subtitle: _cancel != null
            ? 'Complete sign-in in your browser…'
            : 'Sign in with Google to enable account features. Local data never requires an account.',
        trailing: _cancel != null
            ? TextButton(
                onPressed: () => _cancel?.complete(),
                child: const Text('Cancel'),
              )
            : FilledButton(
                onPressed: _signIn,
                child: const Text('Sign in with Google'),
              ),
      );
    }
    return content;
  }

  Widget _row({
    required Widget icon,
    required String title,
    required String subtitle,
    Widget? trailing,
  }) => Padding(
    padding: const EdgeInsets.all(14),
    child: Row(
      children: [
        icon,
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(fontSize: 12, color: context.colors.textMuted),
              ),
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 12), trailing],
      ],
    ),
  );
}
