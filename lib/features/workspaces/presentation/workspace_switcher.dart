import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/app_database.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/dialogs.dart';
import '../../cloud_sync/domain/cloud_models.dart';
import '../../cloud_sync/presentation/cloud_sync_controller.dart';
import '../domain/workspace.dart';
import 'share_workspace_dialog.dart';
import 'workspace_providers.dart';

Future<void> newWorkspaceCommand(BuildContext context, WidgetRef ref) async {
  final name = await promptDialog(
    context,
    title: 'New workspace',
    confirmLabel: 'Create',
  );
  if (name == null || !context.mounted) return;
  await guarded(
    context,
    () => ref.read(activeWorkspaceIdProvider.notifier).create(name),
  );
}

Future<void> renameWorkspaceCommand(
  BuildContext context,
  WidgetRef ref,
  Workspace workspace,
) async {
  final name = await promptDialog(
    context,
    title: 'Rename workspace',
    initial: workspace.name,
    confirmLabel: 'Rename',
  );
  if (name == null || !context.mounted) return;
  await guarded(
    context,
    () =>
        ref.read(activeWorkspaceIdProvider.notifier).rename(workspace.id, name),
  );
}

Future<void> deleteWorkspaceCommand(
  BuildContext context,
  WidgetRef ref,
  Workspace workspace,
) async {
  final role = ref.read(cloudSyncProvider).sharedWorkspaces[workspace.id];
  if (role == WorkspaceRole.member) {
    // Not ours to delete: leaving removes it from this computer.
    return showShareWorkspaceDialog(context, workspace);
  }
  final ok = await confirmDialog(
    context,
    title: 'Delete workspace',
    message: role == WorkspaceRole.owner
        ? 'Delete "${workspace.name}" for everyone? All of its collections '
              'and environments are removed for every member. This cannot be '
              'undone. Export anything you want to keep first.'
        : 'Delete "${workspace.name}" with all of its collections, '
              'environments, history and stored secrets? This cannot be '
              'undone. Export anything you want to keep first.',
    confirmLabel: 'Delete workspace',
  );
  if (!ok || !context.mounted) return;
  if (role == WorkspaceRole.owner) {
    await ref
        .read(activeWorkspaceIdProvider.notifier)
        .select(defaultWorkspaceId);
  }
  if (!context.mounted) return;
  await guarded(
    context,
    () => role == WorkspaceRole.owner
        ? ref
              .read(cloudSyncProvider.notifier)
              .deleteSharedWorkspace(workspace.id)
        : ref.read(activeWorkspaceIdProvider.notifier).delete(workspace.id),
    success: 'Workspace "${workspace.name}" deleted',
  );
}

/// Sidebar header showing the active workspace; opens a menu to switch,
/// create, rename and delete workspaces.
class WorkspaceSwitcher extends ConsumerStatefulWidget {
  const WorkspaceSwitcher({super.key});

  @override
  ConsumerState<WorkspaceSwitcher> createState() => _WorkspaceSwitcherState();
}

class _WorkspaceSwitcherState extends ConsumerState<WorkspaceSwitcher> {
  final _menu = MenuController();
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final workspaces = ref.watch(workspacesProvider).value ?? const [];
    final activeId = ref.watch(activeWorkspaceIdProvider);
    final active = ref.watch(activeWorkspaceProvider);
    final name = active?.name ?? defaultWorkspaceName;
    final shared = ref.watch(
      cloudSyncProvider.select((s) => s.sharedWorkspaces),
    );
    final activeRole = active == null ? null : shared[active.id];

    return MenuAnchor(
      controller: _menu,
      onOpen: () => setState(() {}),
      onClose: () => setState(() {}),
      alignmentOffset: const Offset(8, 2),
      style: const MenuStyle(minimumSize: WidgetStatePropertyAll(Size(240, 0))),
      menuChildren: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
          child: Text(
            'WORKSPACES',
            style: TextStyle(
              fontSize: 10.5,
              letterSpacing: 0.6,
              fontWeight: FontWeight.w600,
              color: colors.textMuted,
            ),
          ),
        ),
        for (final w in workspaces)
          MenuItemButton(
            key: ValueKey('workspace-item-${w.id}'),
            leadingIcon: WorkspaceAvatar(name: w.name, size: 20),
            trailingIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (shared.containsKey(w.id))
                  Tooltip(
                    message: 'Shared with your team',
                    child: Icon(
                      Icons.group_outlined,
                      size: 15,
                      color: colors.textMuted,
                    ),
                  ),
                if (w.id == activeId) ...[
                  const SizedBox(width: 6),
                  Icon(Icons.check, size: 16, color: colors.accent),
                ],
              ],
            ),
            onPressed: () =>
                ref.read(activeWorkspaceIdProvider.notifier).select(w.id),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(w.name, overflow: TextOverflow.ellipsis),
            ),
          ),
        const Divider(height: 9),
        MenuItemButton(
          leadingIcon: const Icon(Icons.add, size: 18),
          onPressed: () => newWorkspaceCommand(context, ref),
          child: const Text('New workspace…'),
        ),
        if (active != null && active.id != defaultWorkspaceId)
          MenuItemButton(
            key: const ValueKey('share-workspace-menu'),
            leadingIcon: const Icon(Icons.group_add_outlined, size: 18),
            onPressed: () => showShareWorkspaceDialog(context, active),
            child: Text(
              activeRole == null
                  ? 'Share workspace…'
                  : activeRole == WorkspaceRole.owner
                  ? 'Manage members…'
                  : 'Members…',
            ),
          ),
        if (active != null) ...[
          MenuItemButton(
            leadingIcon: const Icon(Icons.edit_outlined, size: 18),
            onPressed: () => renameWorkspaceCommand(context, ref, active),
            child: const Text('Rename workspace…'),
          ),
          if (active.id != defaultWorkspaceId)
            MenuItemButton(
              leadingIcon: Icon(
                Icons.delete_outline,
                size: 18,
                color: colors.danger,
              ),
              onPressed: () => deleteWorkspaceCommand(context, ref, active),
              child: Text(
                activeRole == WorkspaceRole.member
                    ? 'Leave workspace…'
                    : 'Delete workspace…',
                style: TextStyle(color: colors.danger),
              ),
            ),
        ],
      ],
      child: Tooltip(
        message: 'Switch workspace',
        waitDuration: const Duration(milliseconds: 600),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            key: const ValueKey('workspace-switcher'),
            behavior: HitTestBehavior.opaque,
            onTap: () => _menu.isOpen ? _menu.close() : _menu.open(),
            child: Container(
              height: 34,
              margin: const EdgeInsets.fromLTRB(8, 8, 8, 2),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                color: _hover || _menu.isOpen ? colors.hover : null,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  WorkspaceAvatar(name: name, size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.unfold_more,
                    size: 16,
                    color: colors.textSecondary,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Rounded square with the workspace's initial, tinted from its name.
class WorkspaceAvatar extends StatelessWidget {
  const WorkspaceAvatar({super.key, required this.name, this.size = 22});

  final String name;
  final double size;

  static const _palette = [
    Color(0xFF8B7CF6),
    Color(0xFF5EB1EF),
    Color(0xFF4CC38A),
    Color(0xFFE5B65C),
    Color(0xFFF0707A),
    Color(0xFF4FC4CF),
    Color(0xFFB79CF7),
  ];

  @override
  Widget build(BuildContext context) {
    final trimmed = name.trim();
    final initial = trimmed.isEmpty ? '?' : trimmed.characters.first;
    final color =
        _palette[trimmed.codeUnits.fold(0, (a, b) => a + b) % _palette.length];
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(size * 0.28),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Text(
        initial.toUpperCase(),
        style: TextStyle(
          fontSize: size * 0.5,
          fontWeight: FontWeight.w700,
          color: color,
          height: 1,
        ),
      ),
    );
  }
}
