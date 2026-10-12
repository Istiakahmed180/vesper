import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/dialogs.dart';
import '../../workspace/domain/workspace_models.dart';
import '../../workspace/presentation/workspace_controller.dart';
import '../domain/app_release.dart';
import 'update_controller.dart';

/// Asks about unsaved tabs, then downloads and installs the update.
Future<void> startUpdate(BuildContext context, WidgetRef ref) async {
  final dirty = ref
      .read(workspaceProvider)
      .tabs
      .whereType<RequestTab>()
      .where((t) => t.isDirty)
      .length;
  if (dirty > 0) {
    final ok = await confirmDialog(
      context,
      title: 'Update and restart?',
      message:
          '$dirty tab(s) have unsaved changes that will be lost when '
          '${AppConstants.appName} restarts. Save them first to keep them.',
      confirmLabel: 'Update anyway',
    );
    if (!ok) return;
  }
  await ref.read(updateProvider.notifier).install();
}

Future<void> showReleaseNotes(BuildContext context, AppRelease release) =>
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'What\'s new in ${AppConstants.appName} ${release.version}',
        ),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: SelectableText(
              release.notes.trim().isEmpty
                  ? 'No release notes.'
                  : release.notes.trim(),
              style: AppTheme.mono(context, size: 12.5),
            ),
          ),
        ),
        actions: [
          if (release.pageUrl.isNotEmpty)
            TextButton(
              onPressed: () => launchUrl(Uri.parse(release.pageUrl)),
              child: const Text('Open on GitHub'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );

/// Bar above the workspace announcing a new version.
class UpdateBanner extends ConsumerWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(updateProvider);
    final release = state.release;
    final visible =
        release != null &&
        !state.dismissed &&
        (state.phase == UpdatePhase.available ||
            state.phase == UpdatePhase.downloading ||
            state.phase == UpdatePhase.failed);
    if (!visible) return const SizedBox.shrink();

    final colors = context.colors;
    final downloading = state.phase == UpdatePhase.downloading;
    final failed = state.phase == UpdatePhase.failed;
    return Container(
      key: const ValueKey('update-banner'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: colors.accent.withValues(alpha: 0.12),
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          Icon(
            failed ? Icons.error_outline : Icons.system_update_alt,
            size: 16,
            color: failed ? colors.danger : colors.accent,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              failed
                  ? state.error ?? 'The update failed.'
                  : downloading
                  ? 'Downloading ${AppConstants.appName} ${release.version}… '
                        '${(state.progress * 100).round()}%'
                  : '${AppConstants.appName} ${release.version} is available. '
                        'You have ${ref.watch(currentVersionProvider)}.',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
          if (downloading) ...[
            SizedBox(
              width: 140,
              child: LinearProgressIndicator(value: state.progress),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: ref.read(updateProvider.notifier).cancelDownload,
              child: const Text('Cancel'),
            ),
          ] else ...[
            TextButton(
              onPressed: () => showReleaseNotes(context, release),
              child: const Text('What\'s new'),
            ),
            TextButton(
              onPressed: ref.read(updateProvider.notifier).dismiss,
              child: const Text('Later'),
            ),
            const SizedBox(width: 4),
            FilledButton(
              key: const ValueKey('update-install'),
              onPressed: () => startUpdate(context, ref),
              child: Text(failed ? 'Try again' : 'Update & restart'),
            ),
          ],
        ],
      ),
    );
  }
}

/// "Updates" rows for Settings → General.
class UpdateSettingsStatus extends ConsumerWidget {
  const UpdateSettingsStatus({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(updateProvider);
    final colors = context.colors;
    final current = ref.watch(currentVersionProvider);
    final supported = ref.watch(updateServiceProvider) != null;
    final release = state.release;

    final (String text, Color? color) = switch (state.phase) {
      _ when !supported => ('Updates are not available on this system.', null),
      UpdatePhase.checking => ('Checking for updates…', null),
      UpdatePhase.upToDate => ('You have the latest version.', colors.success),
      UpdatePhase.available => (
        'Version ${release?.version} is available.',
        colors.accent,
      ),
      UpdatePhase.downloading => (
        'Downloading ${release?.version}… ${(state.progress * 100).round()}%',
        null,
      ),
      UpdatePhase.failed => (
        state.error ?? 'The update failed.',
        colors.danger,
      ),
      UpdatePhase.idle => ('Version $current', null),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${AppConstants.appName} $current',
                  style: const TextStyle(fontSize: 13),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    text,
                    key: const ValueKey('update-status'),
                    style: TextStyle(
                      fontSize: 11.5,
                      color: color ?? colors.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          if (release != null &&
              (state.phase == UpdatePhase.available ||
                  state.phase == UpdatePhase.failed)) ...[
            TextButton(
              onPressed: () => showReleaseNotes(context, release),
              child: const Text('What\'s new'),
            ),
            const SizedBox(width: 6),
            FilledButton(
              onPressed: () => startUpdate(context, ref),
              child: const Text('Update & restart'),
            ),
          ] else
            OutlinedButton(
              key: const ValueKey('check-updates'),
              onPressed: !supported || state.busy
                  ? null
                  : () => ref.read(updateProvider.notifier).check(manual: true),
              child: const Text('Check for updates'),
            ),
        ],
      ),
    );
  }
}
