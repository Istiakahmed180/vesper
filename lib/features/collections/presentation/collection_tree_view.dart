import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/dialogs.dart';
import '../../../shared/widgets/method_badge.dart';
import '../../../shared/widgets/section_tabs.dart';
import '../../api_client/domain/models/api_request.dart';
import '../../import_export/presentation/import_export_actions.dart';
import '../../sync/presentation/sync_dialog.dart';
import '../../workspace/domain/workspace_models.dart';
import '../../workspace/presentation/workspace_controller.dart';
import '../domain/collection_models.dart';
import 'collection_providers.dart';

/// Payload carried while dragging tree nodes.
sealed class TreeDrag {
  const TreeDrag();
}

class RequestDrag extends TreeDrag {
  const RequestDrag(this.request);
  final ApiRequest request;
}

class FolderDrag extends TreeDrag {
  const FolderDrag(this.folder);
  final Folder folder;
}

class CollectionDrag extends TreeDrag {
  const CollectionDrag(this.collection, this.index);
  final Collection collection;
  final int index;
}

/// One visible row of the flattened tree.
class _Row {
  const _Row.collection(this.tree, this.index)
    : node = null,
      depth = 0,
      collectionId = '';
  const _Row.node(this.node, this.depth, this.collectionId, this.index)
    : tree = null;

  final CollectionTree? tree;
  final TreeNode? node;
  final int depth;
  final String collectionId;

  /// Index among siblings (for reordering).
  final int index;
}

class CollectionTreeView extends ConsumerWidget {
  const CollectionTreeView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final treesAsync = ref.watch(collectionTreesProvider);
    final filtered = ref.watch(filteredTreesProvider);
    final expanded = ref.watch(expandedNodesProvider);
    final searching = filtered != null;

    return treesAsync.when(
      loading: () => const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      error: (e, _) => const EmptyState(
        icon: Icons.error_outline,
        title: 'Could not load collections',
      ),
      data: (all) {
        final trees = filtered ?? all;
        if (all.isEmpty) {
          return EmptyState(
            icon: Icons.folder_copy_outlined,
            title: 'No collections yet',
            message:
                'Collections group related requests. Create one or import an existing file.',
            action: Column(
              children: [
                FilledButton(
                  onPressed: () => _createCollection(context, ref),
                  child: const Text('New collection'),
                ),
                const SizedBox(height: 6),
                TextButton(
                  onPressed: () =>
                      ImportExportActions(ref, context).importCollection(),
                  child: const Text('Import…'),
                ),
              ],
            ),
          );
        }
        if (trees.isEmpty) {
          return const EmptyState(icon: Icons.search_off, title: 'No matches');
        }

        final rows = <_Row>[];
        void addNodes(List<TreeNode> nodes, int depth, String cid) {
          for (var i = 0; i < nodes.length; i++) {
            final n = nodes[i];
            rows.add(_Row.node(n, depth, cid, i));
            if (n is FolderNode && (searching || expanded.contains(n.id))) {
              addNodes(n.children, depth + 1, cid);
            }
          }
        }

        for (var i = 0; i < trees.length; i++) {
          final t = trees[i];
          rows.add(_Row.collection(t, i));
          if (searching || expanded.contains(t.collection.id)) {
            addNodes(t.children, 1, t.collection.id);
          }
        }

        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 24),
          itemCount: rows.length,
          itemExtent: 28,
          itemBuilder: (context, i) {
            final row = rows[i];
            if (row.tree != null) {
              return _CollectionRow(
                tree: row.tree!,
                index: row.index,
                expanded:
                    searching || expanded.contains(row.tree!.collection.id),
              );
            }
            return switch (row.node!) {
              final FolderNode f => _FolderRow(
                node: f,
                depth: row.depth,
                index: row.index,
                expanded: searching || expanded.contains(f.id),
              ),
              final RequestNode r => _RequestRow(
                node: r,
                depth: row.depth,
                index: row.index,
              ),
            };
          },
        );
      },
    );
  }
}

Future<void> _createCollection(BuildContext context, WidgetRef ref) async {
  final name = await promptDialog(
    context,
    title: 'New collection',
    confirmLabel: 'Create',
  );
  if (name == null || !context.mounted) return;
  final c = await guarded(
    context,
    () => ref.read(collectionRepositoryProvider).createCollection(name),
  );
  if (c != null) ref.read(expandedNodesProvider.notifier).expand([c.id]);
}

Future<void> newCollectionCommand(BuildContext context, WidgetRef ref) =>
    _createCollection(context, ref);

Future<void> _addRequest(
  BuildContext context,
  WidgetRef ref,
  TreeLocation loc,
) async {
  final saved = await guarded(
    context,
    () => ref
        .read(collectionRepositoryProvider)
        .saveRequest(
          ApiRequest(
            name: 'New request',
            collectionId: loc.collectionId,
            folderId: loc.folderId,
          ),
        ),
  );
  if (saved == null) return;
  ref.read(expandedNodesProvider.notifier).expand([
    loc.collectionId,
    ?loc.folderId,
  ]);
  await ref.read(workspaceProvider.notifier).openSavedRequest(saved.id);
}

Future<void> _addFolder(
  BuildContext context,
  WidgetRef ref,
  TreeLocation loc,
) async {
  final name = await promptDialog(
    context,
    title: 'New folder',
    confirmLabel: 'Create',
  );
  if (name == null || !context.mounted) return;
  final f = await guarded(
    context,
    () => ref
        .read(collectionRepositoryProvider)
        .createFolder(loc.collectionId, name, parentId: loc.folderId),
  );
  if (f != null) {
    ref.read(expandedNodesProvider.notifier).expand([
      loc.collectionId,
      ?loc.folderId,
      f.id,
    ]);
  }
}

/// Shared row chrome: hover, selection, indentation, context menu.
class _TreeRowShell extends StatefulWidget {
  const _TreeRowShell({
    required this.depth,
    required this.child,
    required this.menu,
    this.onTap,
    this.selected = false,
    this.dropHighlight = false,
  });

  final int depth;
  final Widget child;
  final List<Widget> menu;
  final VoidCallback? onTap;
  final bool selected;
  final bool dropHighlight;

  @override
  State<_TreeRowShell> createState() => _TreeRowShellState();
}

class _TreeRowShellState extends State<_TreeRowShell> {
  final _menu = MenuController();
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MenuAnchor(
      controller: _menu,
      menuChildren: widget.menu,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onSecondaryTapUp: (d) => _menu.open(position: d.localPosition),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 6),
            padding: EdgeInsets.only(left: 6.0 + widget.depth * 14, right: 2),
            decoration: BoxDecoration(
              color: widget.dropHighlight
                  ? colors.accentMuted
                  : widget.selected
                  ? colors.selection
                  : (_hover ? colors.hover : null),
              borderRadius: BorderRadius.circular(5),
              border: widget.dropHighlight
                  ? Border.all(color: colors.accent)
                  : null,
            ),
            child: Row(
              children: [
                Expanded(child: widget.child),
                if (_hover || _menu.isOpen)
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      iconSize: 15,
                      tooltip: 'Actions',
                      onPressed: _menu.open,
                      icon: const Icon(Icons.more_horiz),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CollectionRow extends ConsumerWidget {
  const _CollectionRow({
    required this.tree,
    required this.index,
    required this.expanded,
  });
  final CollectionTree tree;
  final int index;
  final bool expanded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final c = tree.collection;
    final repo = ref.read(collectionRepositoryProvider);
    final loc = TreeLocation(c.id);

    return DragTarget<TreeDrag>(
      onWillAcceptWithDetails: (d) => true,
      onAcceptWithDetails: (d) async {
        switch (d.data) {
          case RequestDrag(:final request):
            await guarded(context, () => repo.moveRequest(request.id, loc));
          case FolderDrag(:final folder):
            await guarded(context, () => repo.moveFolder(folder.id, loc));
          case CollectionDrag(:final collection):
            await guarded(
              context,
              () => repo.reorderCollection(collection.id, index),
            );
        }
        ref.read(expandedNodesProvider.notifier).expand([c.id]);
      },
      builder: (context, candidates, _) => Draggable<TreeDrag>(
        data: CollectionDrag(c, index),
        feedback: _DragFeedback(
          label: c.name,
          icon: Icons.folder_copy_outlined,
        ),
        child: _TreeRowShell(
          depth: 0,
          dropHighlight: candidates.isNotEmpty,
          onTap: () => ref.read(expandedNodesProvider.notifier).toggle(c.id),
          menu: [
            MenuItemButton(
              leadingIcon: const Icon(Icons.add, size: 16),
              onPressed: () => _addRequest(context, ref, loc),
              child: const Text('Add request'),
            ),
            MenuItemButton(
              leadingIcon: const Icon(
                Icons.create_new_folder_outlined,
                size: 16,
              ),
              onPressed: () => _addFolder(context, ref, loc),
              child: const Text('Add folder'),
            ),
            const Divider(),
            MenuItemButton(
              leadingIcon: const Icon(Icons.edit_outlined, size: 16),
              onPressed: () async {
                final name = await promptDialog(
                  context,
                  title: 'Rename collection',
                  initial: c.name,
                );
                if (name != null && context.mounted) {
                  await guarded(
                    context,
                    () => repo.updateCollection(c.id, name: name),
                  );
                }
              },
              child: const Text('Rename'),
            ),
            MenuItemButton(
              leadingIcon: const Icon(Icons.copy_outlined, size: 16),
              onPressed: () => guarded(
                context,
                () => repo.duplicateCollection(c.id),
                success: 'Collection duplicated',
              ),
              child: const Text('Duplicate'),
            ),
            MenuItemButton(
              leadingIcon: const Icon(Icons.ios_share, size: 16),
              onPressed: () => ImportExportActions(
                ref,
                context,
              ).exportCollection(c.id, c.name),
              child: const Text('Export…'),
            ),
            MenuItemButton(
              leadingIcon: const Icon(Icons.sync, size: 16),
              onPressed: () => showSyncDialog(context, collectionId: c.id),
              child: const Text('Sync with GitHub…'),
            ),
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
                  title: 'Delete collection',
                  message:
                      'Delete "${c.name}" and its ${tree.requestCount} request(s)? This cannot be undone.',
                );
                if (ok && context.mounted) {
                  await guarded(context, () => repo.deleteCollection(c.id));
                }
              },
              child: Text('Delete', style: TextStyle(color: colors.danger)),
            ),
          ],
          child: Row(
            children: [
              Icon(
                expanded ? Icons.expand_more : Icons.chevron_right,
                size: 16,
                color: colors.textMuted,
              ),
              const SizedBox(width: 4),
              Icon(Icons.folder_copy_outlined, size: 15, color: colors.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  c.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '${tree.requestCount}',
                style: TextStyle(fontSize: 11, color: colors.textMuted),
              ),
              const SizedBox(width: 6),
            ],
          ),
        ),
      ),
    );
  }
}

class _FolderRow extends ConsumerWidget {
  const _FolderRow({
    required this.node,
    required this.depth,
    required this.index,
    required this.expanded,
  });
  final FolderNode node;
  final int depth;
  final int index;
  final bool expanded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final f = node.folder;
    final repo = ref.read(collectionRepositoryProvider);
    final inside = TreeLocation(f.collectionId, f.id);

    return DragTarget<TreeDrag>(
      onWillAcceptWithDetails: (d) => switch (d.data) {
        FolderDrag(:final folder) => folder.id != f.id,
        CollectionDrag() => false,
        _ => true,
      },
      onAcceptWithDetails: (d) async {
        switch (d.data) {
          case RequestDrag(:final request):
            await guarded(context, () => repo.moveRequest(request.id, inside));
          case FolderDrag(:final folder):
            await guarded(context, () => repo.moveFolder(folder.id, inside));
          case CollectionDrag():
            break;
        }
        ref.read(expandedNodesProvider.notifier).expand([f.id]);
      },
      builder: (context, candidates, _) => Draggable<TreeDrag>(
        data: FolderDrag(f),
        feedback: _DragFeedback(label: f.name, icon: Icons.folder_outlined),
        child: _TreeRowShell(
          depth: depth,
          dropHighlight: candidates.isNotEmpty,
          onTap: () => ref.read(expandedNodesProvider.notifier).toggle(f.id),
          menu: [
            MenuItemButton(
              leadingIcon: const Icon(Icons.add, size: 16),
              onPressed: () => _addRequest(context, ref, inside),
              child: const Text('Add request'),
            ),
            MenuItemButton(
              leadingIcon: const Icon(
                Icons.create_new_folder_outlined,
                size: 16,
              ),
              onPressed: () => _addFolder(context, ref, inside),
              child: const Text('Add folder'),
            ),
            const Divider(),
            MenuItemButton(
              leadingIcon: const Icon(Icons.edit_outlined, size: 16),
              onPressed: () async {
                final name = await promptDialog(
                  context,
                  title: 'Rename folder',
                  initial: f.name,
                );
                if (name != null && context.mounted) {
                  await guarded(context, () => repo.renameFolder(f.id, name));
                }
              },
              child: const Text('Rename'),
            ),
            MenuItemButton(
              leadingIcon: const Icon(Icons.copy_outlined, size: 16),
              onPressed: () => guarded(
                context,
                () => repo.duplicateFolder(f.id),
                success: 'Folder duplicated',
              ),
              child: const Text('Duplicate'),
            ),
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
                  title: 'Delete folder',
                  message:
                      'Delete "${f.name}" and its ${node.requestCount} request(s)? This cannot be undone.',
                );
                if (ok && context.mounted) {
                  await guarded(context, () => repo.deleteFolder(f.id));
                }
              },
              child: Text('Delete', style: TextStyle(color: colors.danger)),
            ),
          ],
          child: Row(
            children: [
              Icon(
                expanded ? Icons.expand_more : Icons.chevron_right,
                size: 16,
                color: colors.textMuted,
              ),
              const SizedBox(width: 4),
              Icon(
                expanded ? Icons.folder_open_outlined : Icons.folder_outlined,
                size: 15,
                color: colors.textSecondary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  f.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RequestRow extends ConsumerWidget {
  const _RequestRow({
    required this.node,
    required this.depth,
    required this.index,
  });
  final RequestNode node;
  final int depth;
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final r = node.request;
    final repo = ref.read(collectionRepositoryProvider);
    final ws = ref.read(workspaceProvider.notifier);
    final active = ref.watch(
      workspaceProvider.select((s) {
        final t = s.activeTab;
        return t is RequestTab && t.savedRequestId == r.id;
      }),
    );

    return DragTarget<TreeDrag>(
      onWillAcceptWithDetails: (d) =>
          d.data is RequestDrag && (d.data as RequestDrag).request.id != r.id,
      onAcceptWithDetails: (d) async {
        final dragged = (d.data as RequestDrag).request;
        await guarded(
          context,
          () => repo.moveRequest(
            dragged.id,
            TreeLocation(r.collectionId!, r.folderId),
            index: index,
          ),
        );
      },
      builder: (context, candidates, _) => Draggable<TreeDrag>(
        data: RequestDrag(r),
        feedback: _DragFeedback(label: r.name, method: r),
        child: Stack(
          children: [
            _TreeRowShell(
              depth: depth,
              selected: active,
              onTap: () => ws.openSavedRequest(r.id),
              menu: [
                MenuItemButton(
                  leadingIcon: const Icon(Icons.open_in_new, size: 16),
                  onPressed: () => ws.openSavedRequest(r.id),
                  child: const Text('Open'),
                ),
                MenuItemButton(
                  leadingIcon: const Icon(Icons.edit_outlined, size: 16),
                  onPressed: () async {
                    final name = await promptDialog(
                      context,
                      title: 'Rename request',
                      initial: r.name,
                    );
                    if (name != null && context.mounted) {
                      await guarded(
                        context,
                        () => repo.renameRequest(r.id, name),
                      );
                    }
                  },
                  child: const Text('Rename'),
                ),
                MenuItemButton(
                  leadingIcon: const Icon(Icons.copy_outlined, size: 16),
                  onPressed: () => guarded(
                    context,
                    () => repo.duplicateRequest(r.id),
                    success: 'Request duplicated',
                  ),
                  child: const Text('Duplicate'),
                ),
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
                      title: 'Delete request',
                      message: 'Delete "${r.name}"? This cannot be undone.',
                    );
                    if (ok && context.mounted) {
                      await guarded(context, () => repo.deleteRequest(r.id));
                    }
                  },
                  child: Text('Delete', style: TextStyle(color: colors.danger)),
                ),
              ],
              child: Row(
                children: [
                  const SizedBox(width: 20),
                  MethodBadge(r.method, width: 42),
                  Expanded(
                    child: Text(
                      r.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
            if (candidates.isNotEmpty)
              Positioned(
                top: 0,
                left: 12.0 + depth * 14,
                right: 8,
                child: Container(height: 2, color: colors.accent),
              ),
          ],
        ),
      ),
    );
  }
}

class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.label, this.icon, this.method});
  final String label;
  final IconData? icon;
  final ApiRequest? method;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: colors.panelRaised,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: colors.accent),
          boxShadow: const [
            BoxShadow(blurRadius: 12, color: Color(0x55000000)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (method != null)
              MethodBadge(method!.method)
            else
              Icon(icon, size: 15, color: colors.textSecondary),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(fontSize: 13, color: colors.textPrimary),
            ),
          ],
        ),
      ),
    );
  }
}
