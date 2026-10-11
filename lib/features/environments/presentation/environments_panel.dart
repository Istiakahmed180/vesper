import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/dialogs.dart';
import '../../../shared/widgets/section_tabs.dart';
import '../../import_export/presentation/import_export_actions.dart';
import '../../workspace/presentation/workspace_controller.dart';
import '../../workspaces/presentation/workspace_providers.dart';
import '../domain/environment_models.dart';
import 'environment_providers.dart';

Future<void> newEnvironmentCommand(BuildContext context, WidgetRef ref) async {
  final name = await promptDialog(
    context,
    title: 'New environment',
    confirmLabel: 'Create',
  );
  if (name == null || !context.mounted) return;
  final env = await guarded(
    context,
    () => ref.read(environmentRepositoryProvider).createEnvironment(name),
  );
  if (env != null) {
    ref.read(workspaceProvider.notifier).openEnvironment(env.id, env.name);
  }
}

class EnvironmentsPanel extends ConsumerWidget {
  const EnvironmentsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final envs = ref.watch(environmentsProvider);
    final activeId = ref.watch(activeEnvironmentIdProvider);
    return envs.when(
      loading: () => const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      error: (_, _) => const EmptyState(
        icon: Icons.error_outline,
        title: 'Could not load environments',
      ),
      data: (list) {
        final regular = list.where((e) => !e.isGlobal).toList();
        final globals = list.where((e) => e.isGlobal).firstOrNull;
        return ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            if (globals != null) _EnvRow(env: globals, active: false),
            const SizedBox(height: 6),
            if (regular.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: EmptyState(
                  icon: Icons.layers_outlined,
                  title: 'No environments',
                  message:
                      'Environments hold variables like {{base_url}} so the same requests work against dev and production.',
                  action: FilledButton(
                    onPressed: () => newEnvironmentCommand(context, ref),
                    child: const Text('New environment'),
                  ),
                ),
              ),
            for (final e in regular) _EnvRow(env: e, active: e.id == activeId),
          ],
        );
      },
    );
  }
}

class _EnvRow extends ConsumerStatefulWidget {
  const _EnvRow({required this.env, required this.active});
  final Environment env;
  final bool active;

  @override
  ConsumerState<_EnvRow> createState() => _EnvRowState();
}

class _EnvRowState extends ConsumerState<_EnvRow> {
  final _menu = MenuController();
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final e = widget.env;
    final repo = ref.read(environmentRepositoryProvider);
    final settings = ref.read(activeWorkspaceIdProvider.notifier);
    return MenuAnchor(
      controller: _menu,
      menuChildren: [
        if (!e.isGlobal)
          MenuItemButton(
            leadingIcon: const Icon(Icons.check_circle_outline, size: 16),
            onPressed: () =>
                settings.setActiveEnvironment(widget.active ? null : e.id),
            child: Text(widget.active ? 'Deactivate' : 'Set active'),
          ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.edit_note, size: 16),
          onPressed: () => ref
              .read(workspaceProvider.notifier)
              .openEnvironment(e.id, e.name),
          child: const Text('Edit variables'),
        ),
        if (!e.isGlobal) ...[
          MenuItemButton(
            leadingIcon: const Icon(Icons.edit_outlined, size: 16),
            onPressed: () async {
              final name = await promptDialog(
                context,
                title: 'Rename environment',
                initial: e.name,
              );
              if (name != null && context.mounted) {
                await guarded(
                  context,
                  () => repo.saveEnvironment(e.copyWith(name: name)),
                );
              }
            },
            child: const Text('Rename'),
          ),
          MenuItemButton(
            leadingIcon: const Icon(Icons.copy_outlined, size: 16),
            onPressed: () => guarded(
              context,
              () => repo.duplicateEnvironment(e.id),
              success: 'Environment duplicated',
            ),
            child: const Text('Duplicate'),
          ),
        ],
        MenuItemButton(
          leadingIcon: const Icon(Icons.ios_share, size: 16),
          onPressed: () =>
              ImportExportActions(ref, context).exportEnvironment(e),
          child: const Text('Export…'),
        ),
        if (!e.isGlobal) ...[
          const Divider(),
          MenuItemButton(
            leadingIcon: Icon(
              Icons.delete_outline,
              size: 16,
              color: colors.danger,
            ),
            onPressed: () async {
              final ok = await confirmDialog(
                context,
                title: 'Delete environment',
                message:
                    'Delete "${e.name}" and its ${e.variables.length} variable(s)? This cannot be undone.',
              );
              if (!ok || !context.mounted) return;
              await guarded(context, () async {
                if (widget.active) await settings.setActiveEnvironment(null);
                await repo.deleteEnvironment(e.id);
              });
            },
            child: Text('Delete', style: TextStyle(color: colors.danger)),
          ),
        ],
      ],
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => ref
              .read(workspaceProvider.notifier)
              .openEnvironment(e.id, e.name),
          onSecondaryTapUp: (d) => _menu.open(position: d.localPosition),
          child: Container(
            height: 32,
            margin: const EdgeInsets.symmetric(horizontal: 6),
            padding: const EdgeInsets.only(left: 6, right: 2),
            decoration: BoxDecoration(
              color: _hover ? colors.hover : null,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Row(
              children: [
                if (e.isGlobal)
                  Icon(Icons.public, size: 16, color: colors.textSecondary)
                else
                  Tooltip(
                    message: widget.active
                        ? 'Active environment'
                        : 'Set as active',
                    child: InkWell(
                      onTap: () => settings.setActiveEnvironment(
                        widget.active ? null : e.id,
                      ),
                      child: Icon(
                        widget.active
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        size: 16,
                        color: widget.active
                            ? colors.success
                            : colors.textMuted,
                      ),
                    ),
                  ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    e.name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: widget.active
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                ),
                Text(
                  '${e.variables.length}',
                  style: TextStyle(fontSize: 11, color: colors.textMuted),
                ),
                SizedBox(
                  width: 28,
                  child: _hover
                      ? IconButton(
                          padding: EdgeInsets.zero,
                          iconSize: 15,
                          onPressed: _menu.open,
                          icon: const Icon(Icons.more_horiz),
                        )
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact selector shown in the top bar.
class EnvironmentSelector extends ConsumerWidget {
  const EnvironmentSelector({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final envs =
        (ref.watch(environmentsProvider).value ?? const <Environment>[])
            .where((e) => !e.isGlobal)
            .toList();
    final active = ref.watch(activeEnvironmentProvider);
    return MenuAnchor(
      builder: (context, controller, _) => InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => controller.isOpen ? controller.close() : controller.open(),
        child: Container(
          height: 28,
          constraints: const BoxConstraints(maxWidth: 220),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            border: Border.all(color: colors.border),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.layers_outlined,
                size: 14,
                color: active == null ? colors.textMuted : colors.success,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  active?.name ?? 'No environment',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: active == null
                        ? colors.textSecondary
                        : colors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.expand_more, size: 16, color: colors.textMuted),
            ],
          ),
        ),
      ),
      menuChildren: [
        MenuItemButton(
          leadingIcon: Icon(active == null ? Icons.check : null, size: 16),
          onPressed: () => ref
              .read(activeWorkspaceIdProvider.notifier)
              .setActiveEnvironment(null),
          child: const Text('No environment'),
        ),
        for (final e in envs)
          MenuItemButton(
            leadingIcon: Icon(
              active?.id == e.id ? Icons.check : null,
              size: 16,
            ),
            onPressed: () => ref
                .read(activeWorkspaceIdProvider.notifier)
                .setActiveEnvironment(e.id),
            child: Text(e.name),
          ),
        const Divider(),
        MenuItemButton(
          leadingIcon: const Icon(Icons.add, size: 16),
          onPressed: () => newEnvironmentCommand(context, ref),
          child: const Text('New environment…'),
        ),
        if (active != null)
          MenuItemButton(
            leadingIcon: const Icon(Icons.edit_note, size: 16),
            onPressed: () => ref
                .read(workspaceProvider.notifier)
                .openEnvironment(active.id, active.name),
            child: Text('Edit ${active.name}'),
          ),
      ],
    );
  }
}
