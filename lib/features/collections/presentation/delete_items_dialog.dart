import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/dialogs.dart';
import '../../../shared/widgets/method_badge.dart';
import '../domain/collection_models.dart';
import 'collection_providers.dart';

/// Lets the user tick folders and requests inside a collection (or inside
/// [folderId] when given) and deletes the ticked ones.
Future<void> showDeleteItemsDialog(
  BuildContext context, {
  required String collectionId,
  String? folderId,
  required String title,
}) => showDialog<void>(
  context: context,
  builder: (_) => _DeleteItemsDialog(
    collectionId: collectionId,
    folderId: folderId,
    title: title,
  ),
);

class _DeleteItemsDialog extends ConsumerStatefulWidget {
  const _DeleteItemsDialog({
    required this.collectionId,
    required this.folderId,
    required this.title,
  });

  final String collectionId;
  final String? folderId;
  final String title;

  @override
  ConsumerState<_DeleteItemsDialog> createState() => _DeleteItemsDialogState();
}

class _DeleteItemsDialogState extends ConsumerState<_DeleteItemsDialog> {
  /// Ticked folder and request ids. A folder with children is ticked exactly
  /// when all of its children are.
  final _selected = <String>{};
  bool _deleting = false;

  /// Children of the collection or folder, from the unfiltered tree.
  List<TreeNode> _roots() {
    final trees = ref.watch(collectionTreesProvider).value ?? const [];
    final tree = trees
        .where((t) => t.collection.id == widget.collectionId)
        .firstOrNull;
    if (tree == null) return const [];
    if (widget.folderId == null) return tree.children;
    FolderNode? find(List<TreeNode> nodes) {
      for (final n in nodes) {
        if (n is! FolderNode) continue;
        if (n.id == widget.folderId) return n;
        final hit = find(n.children);
        if (hit != null) return hit;
      }
      return null;
    }

    return find(tree.children)?.children ?? const [];
  }

  void _setAll(TreeNode node, bool value) {
    value ? _selected.add(node.id) : _selected.remove(node.id);
    if (node is FolderNode) {
      for (final c in node.children) {
        _setAll(c, value);
      }
    }
  }

  /// Re-derives folder ticks from their children, bottom-up.
  void _normalize(List<TreeNode> nodes) {
    for (final n in nodes) {
      if (n is FolderNode && n.children.isNotEmpty) {
        _normalize(n.children);
        n.children.every((c) => _selected.contains(c.id))
            ? _selected.add(n.id)
            : _selected.remove(n.id);
      }
    }
  }

  bool? _state(TreeNode node) {
    if (_selected.contains(node.id)) return true;
    if (node is FolderNode && node.children.any((c) => _state(c) != false)) {
      return null;
    }
    return false;
  }

  void _toggle(TreeNode node, List<TreeNode> roots) {
    setState(() {
      _setAll(node, _state(node) != true);
      _normalize(roots);
    });
  }

  /// Fewest delete calls: a ticked folder takes its contents with it.
  List<TreeNode> _targets(List<TreeNode> nodes) => [
    for (final n in nodes)
      if (_selected.contains(n.id))
        n
      else if (n is FolderNode)
        ..._targets(n.children),
  ];

  Future<void> _delete(List<TreeNode> roots) async {
    final targets = _targets(roots);
    if (targets.isEmpty) return;
    setState(() => _deleting = true);
    final repo = ref.read(collectionRepositoryProvider);
    final count = _selected.length;
    final ok = await guarded(context, () async {
      for (final n in targets) {
        switch (n) {
          case FolderNode():
            await repo.deleteFolder(n.id);
          case RequestNode():
            await repo.deleteRequest(n.id);
        }
      }
      return true;
    }, success: 'Deleted $count item(s)');
    if (!mounted) return;
    if (ok == true) {
      Navigator.pop(context);
    } else {
      setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final roots = _roots();
    final rows = <(TreeNode, int)>[];
    void flatten(List<TreeNode> nodes, int depth) {
      for (final n in nodes) {
        rows.add((n, depth));
        if (n is FolderNode) flatten(n.children, depth + 1);
      }
    }

    flatten(roots, 0);
    final all =
        rows.isNotEmpty && rows.every((r) => _selected.contains(r.$1.id));
    final count = _selected.length;

    return AlertDialog(
      title: Text('Delete items in "${widget.title}"'),
      content: SizedBox(
        width: 460,
        height: 380,
        child: rows.isEmpty
            ? Center(
                child: Text(
                  'Nothing to delete.',
                  style: TextStyle(color: colors.textMuted),
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _CheckRow(
                    key: const ValueKey('delete-items-all'),
                    value: all ? true : (count == 0 ? false : null),
                    onTap: _deleting
                        ? null
                        : () => setState(() {
                            for (final n in roots) {
                              _setAll(n, !all);
                            }
                          }),
                    child: const Text(
                      'Select all',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Divider(height: 1, color: colors.border),
                  Expanded(
                    child: ListView.builder(
                      itemCount: rows.length,
                      itemExtent: 30,
                      itemBuilder: (context, i) {
                        final (node, depth) = rows[i];
                        return _CheckRow(
                          depth: depth,
                          value: _state(node),
                          onTap: _deleting ? null : () => _toggle(node, roots),
                          child: Row(
                            children: [
                              switch (node) {
                                FolderNode() => Icon(
                                  Icons.folder_outlined,
                                  size: 15,
                                  color: colors.textSecondary,
                                ),
                                RequestNode(:final request) => MethodBadge(
                                  request.method,
                                  width: 42,
                                ),
                              },
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  node.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Deleting a folder deletes everything inside it. '
                    'This cannot be undone.',
                    style: TextStyle(fontSize: 12, color: colors.textMuted),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: _deleting ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('delete-items-confirm'),
          style: FilledButton.styleFrom(backgroundColor: colors.danger),
          onPressed: count == 0 || _deleting ? null : () => _delete(roots),
          child: Text(count == 0 ? 'Delete' : 'Delete $count item(s)'),
        ),
      ],
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({
    super.key,
    required this.value,
    required this.onTap,
    required this.child,
    this.depth = 0,
  });

  final bool? value;
  final VoidCallback? onTap;
  final Widget child;
  final int depth;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(5),
    child: Padding(
      padding: EdgeInsets.only(left: depth * 20.0),
      child: Row(
        children: [
          Checkbox(
            value: value,
            tristate: true,
            onChanged: onTap == null ? null : (_) => onTap!(),
          ),
          Expanded(
            child: DefaultTextStyle.merge(
              style: const TextStyle(fontSize: 13),
              child: child,
            ),
          ),
        ],
      ),
    ),
  );
}
