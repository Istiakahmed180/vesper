import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../github/presentation/github_providers.dart';
import 'cloud_sync_controller.dart';

/// Status-bar item: sync state, click to sync now.
class CloudSyncStatus extends ConsumerWidget {
  const CloudSyncStatus({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final sync = ref.watch(cloudSyncProvider);
    final last = sync.lastSyncedAt;
    final (
      IconData icon,
      String label,
      String tooltip,
      Color? color,
    ) = switch (sync.phase) {
      CloudSyncPhase.unavailable || CloudSyncPhase.signedOut => (
        Icons.cloud_off_outlined,
        'Local only',
        'Sign in with Google to sync across computers',
        null,
      ),
      CloudSyncPhase.connecting || CloudSyncPhase.syncing => (
        Icons.sync,
        'Syncing…',
        'Syncing with your account',
        null,
      ),
      CloudSyncPhase.synced => (
        Icons.cloud_done_outlined,
        'Synced',
        last == null
            ? 'Up to date'
            : 'Synced ${Formatters.relativeTime(last)} · click to sync now',
        colors.success,
      ),
      CloudSyncPhase.offline => (
        Icons.cloud_off_outlined,
        'Offline',
        '${sync.message ?? 'The sync server is unreachable'}. Changes are kept and uploaded later.',
        colors.warning,
      ),
      CloudSyncPhase.error => (
        Icons.error_outline,
        'Sync error',
        sync.message ?? 'Sync failed',
        colors.danger,
      ),
      CloudSyncPhase.accountChanged => (
        Icons.pause_circle_outline,
        'Sync paused',
        'This computer has data from ${sync.previousAccount}. Click to choose what to do.',
        colors.warning,
      ),
    };
    final style = TextStyle(fontSize: 11.5, color: colors.textMuted);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        key: const ValueKey('cloud-sync-status'),
        onTap: switch (sync.phase) {
          CloudSyncPhase.accountChanged => () => showAccountChangedDialog(
            context,
            sync.previousAccount ?? 'another account',
          ),
          CloudSyncPhase.unavailable || CloudSyncPhase.signedOut => null,
          _ => () => unawaited(ref.read(cloudSyncProvider.notifier).syncNow()),
        },
        child: Padding(
          padding: const EdgeInsets.only(right: 16),
          child: Row(
            children: [
              Icon(icon, size: 12, color: color ?? colors.textMuted),
              const SizedBox(width: 5),
              Text(label, style: style),
            ],
          ),
        ),
      ),
    );
  }
}

/// Settings › Accounts card describing cloud sync.
class CloudSyncCard extends ConsumerWidget {
  const CloudSyncCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final sync = ref.watch(cloudSyncProvider);
    final github = ref.watch(githubSessionProvider).value;
    final google = ref.watch(authSessionProvider).value;
    final last = sync.lastSyncedAt;

    final (String title, String subtitle) = switch (sync.phase) {
      CloudSyncPhase.unavailable => (
        'Cloud sync is not configured',
        'Set SUPABASE_URL and SUPABASE_ANON_KEY when building Vesper.',
      ),
      CloudSyncPhase.signedOut when github != null && google == null => (
        'Not available with GitHub sign-in',
        'Cloud sync uses your Google account. Your data stays on this computer.',
      ),
      CloudSyncPhase.signedOut => (
        'Off',
        'Sign in with Google to keep workspaces, collections, environments '
            'and history in sync on every computer.',
      ),
      CloudSyncPhase.connecting => ('Connecting…', 'Signing in to cloud sync.'),
      CloudSyncPhase.syncing => ('Syncing…', 'Exchanging changes.'),
      CloudSyncPhase.synced => (
        'Up to date',
        last == null
            ? 'Synced.'
            : 'Last synced ${Formatters.relativeTime(last)}.',
      ),
      CloudSyncPhase.offline => (
        'Offline',
        'Changes are kept on this computer and uploaded when the connection returns.',
      ),
      CloudSyncPhase.error => ('Sync error', sync.message ?? 'Sync failed.'),
      CloudSyncPhase.accountChanged => (
        'Paused',
        'This computer has data from ${sync.previousAccount}.',
      ),
    };
    final canSync = sync.isActive && sync.phase != CloudSyncPhase.syncing;

    return Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Icon(
            sync.phase == CloudSyncPhase.synced
                ? Icons.cloud_done_outlined
                : Icons.cloud_outlined,
            size: 30,
            color: sync.phase == CloudSyncPhase.synced
                ? colors.success
                : colors.textMuted,
          ),
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
          if (sync.phase == CloudSyncPhase.accountChanged)
            FilledButton(
              onPressed: () => showAccountChangedDialog(
                context,
                sync.previousAccount ?? 'another account',
              ),
              child: const Text('Choose…'),
            )
          else if (sync.isActive)
            OutlinedButton(
              key: const ValueKey('cloud-sync-now'),
              onPressed: canSync
                  ? () => ref.read(cloudSyncProvider.notifier).syncNow()
                  : null,
              child: const Text('Sync now'),
            ),
        ],
      ),
    );
  }
}

enum _AccountChoice { replace, merge, signOut }

/// Asks what to do with data from a different account on this computer.
Future<void> showAccountChangedDialog(
  BuildContext context,
  String previousAccount,
) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final choice = await showDialog<_AccountChoice>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Data from another account'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Text(
          'The workspaces and collections on this computer belong to '
          '$previousAccount. What should happen with them?',
          style: TextStyle(fontSize: 13, color: context.colors.textSecondary),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, _AccountChoice.signOut),
          child: const Text('Sign out'),
        ),
        OutlinedButton(
          onPressed: () => Navigator.pop(context, _AccountChoice.merge),
          child: const Text('Add them to my account'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _AccountChoice.replace),
          child: const Text('Replace with my account'),
        ),
      ],
    ),
  );
  switch (choice) {
    case _AccountChoice.replace:
      await container
          .read(cloudSyncProvider.notifier)
          .resolveAccountChange(replaceLocalData: true);
    case _AccountChoice.merge:
      await container
          .read(cloudSyncProvider.notifier)
          .resolveAccountChange(replaceLocalData: false);
    case _AccountChoice.signOut:
      await container.read(authSessionProvider.notifier).signOut();
    case null:
      break;
  }
}
