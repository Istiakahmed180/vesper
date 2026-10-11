import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/dialogs.dart';
import '../../../shared/widgets/section_tabs.dart';
import '../../github/data/github_api.dart';
import '../../github/domain/github_models.dart';
import '../../github/presentation/github_connect_dialog.dart';
import '../../github/presentation/github_providers.dart';
import '../../github/presentation/repo_picker.dart';
import '../../workspaces/presentation/workspace_providers.dart';
import '../data/sync_data.dart';
import '../domain/sync_models.dart';
import '../domain/sync_service.dart';

final syncStateStoreProvider = Provider<SyncStateStore>(
  (ref) => DriftSyncStateStore(ref.watch(databaseProvider)),
);

Future<void> showSyncDialog(BuildContext context, {String? collectionId}) =>
    showDialog<void>(
      context: context,
      builder: (_) => _SyncDialog(collectionId: collectionId),
    );

class _SyncDialog extends ConsumerStatefulWidget {
  const _SyncDialog({this.collectionId});
  final String? collectionId;

  @override
  ConsumerState<_SyncDialog> createState() => _SyncDialogState();
}

class _SyncDialogState extends ConsumerState<_SyncDialog> {
  bool _choosingRepo = false;
  Future<SyncPlan>? _plan;
  final Set<String> _busy = {};

  Future<(SyncService, RemoteFileStore)> _engine(SyncTarget target) async {
    final token = await ref.read(githubAuthRepositoryProvider).requireToken();
    final store = GitHubFileStore(
      api: ref.read(githubApiProvider),
      token: token,
      target: target,
      workspaceId: ref.read(activeWorkspaceIdProvider),
    );
    final service = SyncService(
      collections: ref.read(collectionRepositoryProvider),
      states: ref.read(syncStateStoreProvider),
      basePath: target.basePath,
    );
    return (service, store);
  }

  Future<SyncPlan> _buildPlan(SyncTarget target) async {
    try {
      final (service, store) = await _engine(target);
      // Read fresh from the database: the provider may lag behind a delete.
      final trees = await ref
          .read(collectionRepositoryProvider)
          .watchTrees()
          .first;
      return await service.plan(
        store,
        trees,
        only: widget.collectionId == null ? null : {widget.collectionId!},
      );
    } catch (e) {
      await ref.read(githubSessionProvider.notifier).handleFailure(e);
      rethrow;
    }
  }

  void _refresh(SyncTarget target) =>
      setState(() => _plan = _buildPlan(target));

  Future<void> _apply(
    SyncTarget target,
    SyncItem item, {
    required bool push,
  }) async {
    final overwrite = push
        ? item.status.pushOverwritesRemote
        : item.status.pullOverwritesLocal;
    final title = push ? 'Push to GitHub' : 'Pull from GitHub';
    final message = push
        ? (overwrite
              ? 'This replaces "${item.path}" on GitHub with your local version of "${item.name}". '
                    'Changes made on GitHub will be lost (they remain in the repository history).'
              : 'Commit your local version of "${item.name}" to ${target.repo} (${target.branch}) at ${item.path}? '
                    'Secrets are never included.')
        : (item.collectionId == null
              ? 'Import "${item.name}" from GitHub as a new local collection?'
              : 'This replaces your local "${item.name}" with the version on GitHub. Local changes will be lost.');
    final ok = await confirmDialog(
      context,
      title: title,
      message: message,
      confirmLabel: push
          ? (overwrite ? 'Overwrite GitHub' : 'Push')
          : (overwrite ? 'Overwrite local' : 'Pull'),
      destructive: overwrite,
    );
    if (!ok || !mounted) return;
    setState(() => _busy.add(item.path));
    try {
      final (service, store) = await _engine(target);
      if (push) {
        await service.push(store, item, overwrite: overwrite);
      } else {
        await service.pull(store, item);
      }
      if (mounted) {
        showToast(
          context,
          push ? 'Pushed "${item.name}"' : 'Pulled "${item.name}"',
        );
      }
    } on RemoteConflict catch (e) {
      if (mounted) showToast(context, e.message, error: true);
    } catch (e) {
      await ref.read(githubSessionProvider.notifier).handleFailure(e);
      if (mounted) showToast(context, e.userMessage, error: true);
    } finally {
      if (mounted) {
        setState(() => _busy.remove(item.path));
        _refresh(target);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(appConfigProvider);
    final session = ref.watch(githubSessionProvider);
    final target = ref.watch(syncTargetProvider);

    Widget body;
    if (!config.isGitHubConfigured) {
      body = const EmptyState(
        icon: Icons.settings_outlined,
        title: 'GitHub is not configured',
        message:
            'Set GITHUB_CLIENT_ID when building Vesper. See docs/github-integration.md.',
      );
    } else if (session.isLoading || target.isLoading) {
      body = const SizedBox(
        height: 160,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    } else if (session.value == null) {
      body = EmptyState(
        icon: Icons.link,
        title: 'Connect your GitHub account',
        message:
            'Store collections as JSON files in a repository you choose. Nothing is pushed without your confirmation.',
        action: FilledButton(
          onPressed: () => showGitHubConnectDialog(context),
          child: const Text('Connect GitHub'),
        ),
      );
    } else if (target.value == null || _choosingRepo) {
      body = RepoPicker(
        initial: target.value,
        onSelected: (t) async {
          await ref.read(syncTargetProvider.notifier).select(t);
          setState(() {
            _choosingRepo = false;
            _plan = null;
          });
        },
      );
    } else {
      final t = target.value!;
      _plan ??= _buildPlan(t);
      body = _PlanView(
        target: t,
        plan: _plan!,
        busy: _busy,
        onRefresh: () => _refresh(t),
        onChangeRepo: () => setState(() => _choosingRepo = true),
        onPush: (item) => _apply(t, item, push: true),
        onPull: (item) => _apply(t, item, push: false),
      );
    }

    return AlertDialog(
      title: const Text('Sync with GitHub'),
      content: SizedBox(width: 640, child: body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _PlanView extends StatelessWidget {
  const _PlanView({
    required this.target,
    required this.plan,
    required this.busy,
    required this.onRefresh,
    required this.onChangeRepo,
    required this.onPush,
    required this.onPull,
  });

  final SyncTarget target;
  final Future<SyncPlan> plan;
  final Set<String> busy;
  final VoidCallback onRefresh;
  final VoidCallback onChangeRepo;
  final ValueChanged<SyncItem> onPush;
  final ValueChanged<SyncItem> onPull;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.book_outlined, size: 16, color: colors.textSecondary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '${target.repo} · ${target.branch} · /${target.basePath}',
                style: TextStyle(fontSize: 12.5, color: colors.textSecondary),
              ),
            ),
            TextButton(onPressed: onChangeRepo, child: const Text('Change')),
            IconButton(
              tooltip: 'Refresh',
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 380, minHeight: 120),
          child: FutureBuilder<SyncPlan>(
            future: plan,
            builder: (context, snap) {
              if (snap.hasError) {
                return EmptyState(
                  icon: Icons.error_outline,
                  title: 'Could not compare with GitHub',
                  message: snap.error!.userMessage,
                );
              }
              final data = snap.data;
              if (data == null) {
                return const Center(
                  child: CircularProgressIndicator(strokeWidth: 2),
                );
              }
              if (data.items.isEmpty) {
                return const EmptyState(
                  icon: Icons.inbox_outlined,
                  title: 'No collections to sync',
                );
              }
              return ListView.separated(
                shrinkWrap: true,
                itemCount: data.items.length,
                separatorBuilder: (_, _) =>
                    Divider(height: 1, color: colors.border),
                itemBuilder: (context, i) => _ItemRow(
                  item: data.items[i],
                  busy: busy.contains(data.items[i].path),
                  onPush: onPush,
                  onPull: onPull,
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Secrets are never written to GitHub. Pushing creates one commit per collection.',
          style: TextStyle(fontSize: 11.5, color: colors.textMuted),
        ),
      ],
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    required this.item,
    required this.busy,
    required this.onPush,
    required this.onPull,
  });
  final SyncItem item;
  final bool busy;
  final ValueChanged<SyncItem> onPush;
  final ValueChanged<SyncItem> onPull;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final s = item.status;
    final color = switch (s) {
      SyncStatus.unchanged => colors.success,
      SyncStatus.conflict => colors.danger,
      SyncStatus.remoteChanged || SyncStatus.remoteOnly => colors.info,
      _ => colors.warning,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        item.name,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        s.label,
                        style: TextStyle(
                          fontSize: 11,
                          color: color,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    item.path,
                    if (item.localRequestCount != null)
                      'local ${item.localRequestCount} req',
                    if (item.remoteRequestCount != null)
                      'GitHub ${item.remoteRequestCount} req',
                    if (item.lastSyncedAt != null)
                      'synced ${Formatters.relativeTime(item.lastSyncedAt!)}',
                  ].join(' · '),
                  style: TextStyle(fontSize: 11.5, color: colors.textMuted),
                ),
              ],
            ),
          ),
          if (busy)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else ...[
            if (s.canPull)
              TextButton(
                onPressed: () => onPull(item),
                child: Text(
                  s == SyncStatus.conflict
                      ? 'Keep GitHub'
                      : (s == SyncStatus.remoteOnly ? 'Import' : 'Pull'),
                ),
              ),
            if (s.canPush)
              FilledButton(
                onPressed: () => onPush(item),
                style: s == SyncStatus.conflict
                    ? FilledButton.styleFrom(backgroundColor: colors.danger)
                    : null,
                child: Text(s == SyncStatus.conflict ? 'Keep local' : 'Push'),
              ),
          ],
        ],
      ),
    );
  }
}
