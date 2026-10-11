import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/dialogs.dart';
import '../../cloud_sync/domain/cloud_models.dart';
import '../../cloud_sync/presentation/cloud_sync_controller.dart';
import '../domain/workspace.dart';

Future<void> showShareWorkspaceDialog(
  BuildContext context,
  Workspace workspace,
) => showDialog<void>(
  context: context,
  builder: (_) => ShareWorkspaceDialog(workspace: workspace),
);

/// Shares a workspace and manages its members and invites.
class ShareWorkspaceDialog extends ConsumerStatefulWidget {
  const ShareWorkspaceDialog({super.key, required this.workspace});
  final Workspace workspace;

  @override
  ConsumerState<ShareWorkspaceDialog> createState() =>
      _ShareWorkspaceDialogState();
}

class _ShareWorkspaceDialogState extends ConsumerState<ShareWorkspaceDialog> {
  final _email = TextEditingController();
  List<WorkspaceMember>? _members;
  List<String> _invites = const [];
  bool _busy = false;
  String? _error;

  String get _id => widget.workspace.id;
  CloudSyncController get _sync => ref.read(cloudSyncProvider.notifier);

  @override
  void initState() {
    super.initState();
    if (ref.read(cloudSyncProvider).sharedWorkspaces.containsKey(_id)) {
      _load();
    }
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = e.userMessage);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() => _run(() async {
    final members = await _sync.members(_id);
    final invites = await _sync.invites(_id);
    if (mounted) {
      setState(() {
        _members = members;
        _invites = invites;
      });
    }
  });

  Future<void> _share() => _run(() async {
    await _sync.shareWorkspace(_id, widget.workspace.name);
    final members = await _sync.members(_id);
    if (mounted) setState(() => _members = members);
  });

  Future<void> _invite() => _run(() async {
    await _sync.invite(_id, _email.text);
    _email.clear();
    final invites = await _sync.invites(_id);
    if (mounted) setState(() => _invites = invites);
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final sync = ref.watch(cloudSyncProvider);
    final role = sync.sharedWorkspaces[_id];
    final isOwner = role == WorkspaceRole.owner;
    final shared = role != null;

    Widget body;
    if (!sync.isActive) {
      body = Text(
        'Sign in with Google or GitHub to share workspaces with your team.',
        style: TextStyle(fontSize: 13, color: colors.textSecondary),
      );
    } else if (!shared) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Everyone you invite gets this workspace\'s collections, requests '
            'and environments, and sees each other\'s changes live.',
            style: TextStyle(fontSize: 13, color: colors.textSecondary),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const ValueKey('share-workspace'),
            onPressed: _busy ? null : _share,
            icon: const Icon(Icons.group_add_outlined, size: 18),
            label: const Text('Share this workspace'),
          ),
        ],
      );
    } else {
      final members = _members;
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isOwner) ...[
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('invite-email'),
                    controller: _email,
                    enabled: !_busy,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      hintText: 'teammate@example.com',
                      isDense: true,
                    ),
                    onSubmitted: (_) => _invite(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const ValueKey('send-invite'),
                  onPressed: _busy ? null : _invite,
                  child: const Text('Invite'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'They join by signing in to Vesper with this email (Google or '
              'GitHub).',
              style: TextStyle(fontSize: 11.5, color: colors.textMuted),
            ),
            const SizedBox(height: 14),
          ],
          Text(
            'MEMBERS',
            style: TextStyle(
              fontSize: 10.5,
              letterSpacing: 0.6,
              fontWeight: FontWeight.w600,
              color: colors.textMuted,
            ),
          ),
          const SizedBox(height: 6),
          if (members == null)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else ...[
            for (final m in members)
              _PersonRow(
                email: m.email.isEmpty ? 'Member' : m.email,
                label: m.role == WorkspaceRole.owner ? 'Owner' : 'Member',
                onRemove: isOwner && m.role != WorkspaceRole.owner && !_busy
                    ? () => _run(() async {
                        await _sync.removeMember(_id, m.userId);
                        final updated = await _sync.members(_id);
                        if (mounted) setState(() => _members = updated);
                      })
                    : null,
              ),
            for (final email in _invites)
              _PersonRow(
                email: email,
                label: 'Invited',
                muted: true,
                onRemove: isOwner && !_busy
                    ? () => _run(() async {
                        await _sync.cancelInvite(_id, email);
                        final updated = await _sync.invites(_id);
                        if (mounted) setState(() => _invites = updated);
                      })
                    : null,
              ),
          ],
        ],
      );
    }

    return AlertDialog(
      title: Text('Share "${widget.workspace.name}"'),
      content: SizedBox(
        width: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            body,
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: TextStyle(fontSize: 12, color: colors.danger),
              ),
            ],
            const SizedBox(height: 14),
            Text(
              'Tokens, passwords, secret values and history are never shared; '
              'each member enters their own.',
              style: TextStyle(fontSize: 11.5, color: colors.textMuted),
            ),
          ],
        ),
      ),
      actions: [
        if (shared && !isOwner)
          TextButton(
            onPressed: _busy
                ? null
                : () async {
                    final ok = await confirmDialog(
                      context,
                      title: 'Leave workspace',
                      message:
                          'Leave "${widget.workspace.name}"? It is removed from '
                          'this computer; the owner can invite you again.',
                      confirmLabel: 'Leave',
                    );
                    if (!ok || !context.mounted) return;
                    await _run(() => _sync.leaveWorkspace(_id));
                    if (context.mounted && _error == null) {
                      Navigator.pop(context);
                    }
                  },
            child: Text('Leave', style: TextStyle(color: colors.danger)),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({
    required this.email,
    required this.label,
    this.onRemove,
    this.muted = false,
  });

  final String email;
  final String label;
  final VoidCallback? onRemove;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            muted ? Icons.mail_outline : Icons.person_outline,
            size: 18,
            color: colors.textMuted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              email,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: muted ? colors.textSecondary : colors.textPrimary,
              ),
            ),
          ),
          Text(label, style: TextStyle(fontSize: 12, color: colors.textMuted)),
          SizedBox(
            width: 32,
            child: onRemove == null
                ? null
                : IconButton(
                    tooltip: 'Remove',
                    iconSize: 15,
                    onPressed: onRemove,
                    icon: const Icon(Icons.close),
                  ),
          ),
        ],
      ),
    );
  }
}
