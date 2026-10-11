import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/dialogs.dart';
import '../../auth/presentation/account_card.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../cloud_sync/presentation/cloud_sync_widgets.dart';
import '../../sync/presentation/sync_dialog.dart';
import 'github_connect_dialog.dart';
import 'github_providers.dart';

/// Asks for confirmation, then removes the GitHub connection.
Future<void> confirmGitHubDisconnect(
  BuildContext context,
  WidgetRef ref,
) async {
  final ok = await confirmDialog(
    context,
    title: 'Disconnect GitHub',
    message:
        'Sign out of GitHub and remove its token from this computer? '
        '${signOutDataNote(ref)} To fully revoke access, also remove Vesper '
        'under GitHub → Settings → Applications.',
    confirmLabel: 'Disconnect',
  );
  if (!ok || !context.mounted || !await uploadBeforeSignOut(context, ref)) {
    return;
  }
  await ref.read(githubSessionProvider.notifier).disconnect();
}

/// GitHub connection status, repository selection and disconnect.
class GitHubCard extends ConsumerWidget {
  const GitHubCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final configured = ref.watch(appConfigProvider).isGitHubConfigured;
    final session = ref.watch(githubSessionProvider);
    final target = ref.watch(syncTargetProvider).value;

    Widget row({
      required Widget leading,
      required String title,
      required String subtitle,
      List<Widget> actions = const [],
    }) => Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          leading,
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
                  style: TextStyle(fontSize: 12, color: colors.textMuted),
                ),
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );

    if (!configured) {
      return row(
        leading: Icon(Icons.info_outline, color: colors.textMuted),
        title: 'GitHub is not configured',
        subtitle:
            'Provide GITHUB_CLIENT_ID at build time (see docs/github-integration.md).',
      );
    }
    if (session.isLoading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: LinearProgressIndicator(),
      );
    }
    final s = session.value;
    final google = ref.watch(authSessionProvider).value;
    if (s == null && google != null) {
      return row(
        leading: Icon(Icons.hub_outlined, size: 30, color: colors.textMuted),
        title: 'Not available while signed in with Google',
        subtitle:
            'Only one account can be used at a time. Sign out of '
            '${google.account.email} to connect GitHub.',
        actions: const [
          FilledButton(onPressed: null, child: Text('Connect GitHub')),
        ],
      );
    }
    if (s == null) {
      return row(
        leading: Icon(Icons.hub_outlined, size: 30, color: colors.textMuted),
        title: 'Not connected',
        subtitle:
            'Connect with GitHub device authorization. Vesper never sees your password.',
        actions: [
          FilledButton(
            onPressed: () => showGitHubConnectDialog(context),
            child: const Text('Connect GitHub'),
          ),
        ],
      );
    }
    return Column(
      children: [
        row(
          leading: Avatar(
            initials: s.account.login.isEmpty
                ? '?'
                : s.account.login[0].toUpperCase(),
            url: s.account.avatarUrl,
            size: 36,
          ),
          title: s.account.name.isEmpty
              ? s.account.login
              : '${s.account.name} (@${s.account.login})',
          subtitle: s.scopes.isEmpty
              ? 'Connected'
              : 'Connected · scopes: ${s.scopes}',
          actions: [
            OutlinedButton(
              onPressed: () => confirmGitHubDisconnect(context, ref),
              child: const Text('Disconnect'),
            ),
          ],
        ),
        Divider(height: 1, color: colors.border),
        row(
          leading: Icon(Icons.book_outlined, color: colors.textSecondary),
          title: target == null ? 'No repository selected' : target.repo,
          subtitle: target == null
              ? 'Choose where collections are stored.'
              : 'Branch ${target.branch} · folder /${target.basePath}',
          actions: [
            TextButton(
              onPressed: () => launchUrl(
                Uri.parse('https://github.com/settings/applications'),
              ),
              child: const Text('Manage access'),
            ),
            const SizedBox(width: 6),
            FilledButton(
              onPressed: () => showSyncDialog(context),
              child: Text(target == null ? 'Choose…' : 'Open sync'),
            ),
          ],
        ),
      ],
    );
  }
}
