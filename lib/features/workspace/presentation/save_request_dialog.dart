import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../collections/domain/collection_models.dart';
import '../../collections/presentation/collection_providers.dart';

class SaveTarget {
  const SaveTarget(this.name, this.location);
  final String name;
  final TreeLocation location;
}

Future<SaveTarget?> showSaveRequestDialog(
  BuildContext context, {
  required String initialName,
}) => showDialog<SaveTarget>(
  context: context,
  builder: (_) => _SaveRequestDialog(initialName: initialName),
);

class _SaveRequestDialog extends ConsumerStatefulWidget {
  const _SaveRequestDialog({required this.initialName});
  final String initialName;

  @override
  ConsumerState<_SaveRequestDialog> createState() => _SaveRequestDialogState();
}

class _SaveRequestDialogState extends ConsumerState<_SaveRequestDialog> {
  late final _name = TextEditingController(text: widget.initialName);
  String? _collectionId;
  String? _folderId;
  bool _creating = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _newCollection() async {
    setState(() => _creating = true);
    final c = await ref
        .read(collectionRepositoryProvider)
        .createCollection('New collection');
    if (!mounted) return;
    setState(() {
      _collectionId = c.id;
      _folderId = null;
      _creating = false;
    });
  }

  void _submit() {
    final cid = _collectionId;
    if (cid == null || _name.text.trim().isEmpty) return;
    Navigator.pop(
      context,
      SaveTarget(_name.text.trim(), TreeLocation(cid, _folderId)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final trees = ref.watch(collectionTreesProvider).value ?? const [];
    _collectionId ??= trees.firstOrNull?.collection.id;
    final tree = trees
        .where((t) => t.collection.id == _collectionId)
        .firstOrNull;
    final folders = <(String, String)>[];
    void walk(List<TreeNode> nodes, String prefix) {
      for (final n in nodes) {
        if (n is FolderNode) {
          final path = prefix.isEmpty ? n.name : '$prefix / ${n.name}';
          folders.add((n.id, path));
          walk(n.children, path);
        }
      }
    }

    if (tree != null) walk(tree.children, '');

    return AlertDialog(
      title: const Text('Save request'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Request name'),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            Text('Collection', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 6),
            if (trees.isEmpty)
              Text(
                'You have no collections yet.',
                style: TextStyle(color: colors.textSecondary, fontSize: 12.5),
              )
            else
              DropdownButtonFormField<String>(
                initialValue: _collectionId,
                isExpanded: true,
                items: [
                  for (final t in trees)
                    DropdownMenuItem(
                      value: t.collection.id,
                      child: Text(t.collection.name),
                    ),
                ],
                onChanged: (v) => setState(() {
                  _collectionId = v;
                  _folderId = null;
                }),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _creating ? null : _newCollection,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('New collection'),
              ),
            ),
            if (folders.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Folder', style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 6),
              DropdownButtonFormField<String?>(
                key: ValueKey(_collectionId),
                initialValue: _folderId,
                isExpanded: true,
                items: [
                  const DropdownMenuItem(
                    value: null,
                    child: Text('— Collection root —'),
                  ),
                  for (final (id, path) in folders)
                    DropdownMenuItem(value: id, child: Text(path)),
                ],
                onChanged: (v) => setState(() => _folderId = v),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _collectionId == null ? null : _submit,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
