import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/dialogs.dart';
import '../../../workspace/presentation/response_controller.dart';
import '../../../workspace/presentation/workspace_controller.dart';
import '../../domain/models/saved_response.dart';

/// Strip above the response: saves the live response as an example and lists,
/// shows, renames and deletes the request's saved examples.
class ExamplesBar extends ConsumerWidget {
  const ExamplesBar({super.key, required this.tabId});

  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(requestTabProvider(tabId));
    final state = ref.watch(responseProvider(tabId));
    final controller = ref.read(responseProvider(tabId).notifier);
    if (tab == null) return const SizedBox.shrink();
    final examples = tab.draft.examples;
    final shown = state is ResponseSuccess ? state.example : null;
    final canSave = controller.canSaveExample;
    if (examples.isEmpty && !canSave) return const SizedBox.shrink();

    final colors = context.colors;
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          if (examples.isNotEmpty)
            PopupMenuButton<SavedResponse>(
              tooltip: 'Saved examples',
              onSelected: controller.viewExample,
              itemBuilder: (_) => [
                for (final e in examples)
                  PopupMenuItem(
                    value: e,
                    height: 36,
                    child: Row(
                      children: [
                        Icon(
                          e.isSuccess
                              ? Icons.check_circle_outline
                              : Icons.error_outline,
                          size: 14,
                          color: colors.statusColor(e.statusCode),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${e.statusCode}',
                          style: TextStyle(
                            color: colors.statusColor(e.statusCode),
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(e.name, overflow: TextOverflow.ellipsis),
                        ),
                      ],
                    ),
                  ),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.bookmarks_outlined, size: 14),
                    const SizedBox(width: 6),
                    Text(
                      'Examples (${examples.length})',
                      style: const TextStyle(fontSize: 12),
                    ),
                    const Icon(Icons.arrow_drop_down, size: 18),
                  ],
                ),
              ),
            ),
          if (shown != null) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                'Saved example: ${shown.name}'
                '${shown.isTruncated ? ' (body cut)' : ''}',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colors.textMuted, fontSize: 12),
              ),
            ),
            IconButton(
              tooltip: 'Rename example',
              visualDensity: VisualDensity.compact,
              iconSize: 15,
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => _rename(context, controller, shown),
            ),
            IconButton(
              tooltip: 'Delete example',
              visualDensity: VisualDensity.compact,
              iconSize: 15,
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _delete(context, controller, shown),
            ),
            TextButton(
              onPressed: controller.clear,
              child: const Text('Close'),
            ),
          ],
          const Spacer(),
          if (canSave)
            Tooltip(
              message: tab.isSaved
                  ? 'Keep this response on the request'
                  : 'Save the request first',
              child: TextButton.icon(
                icon: const Icon(Icons.bookmark_add_outlined, size: 15),
                label: const Text('Save as example'),
                onPressed: tab.isSaved
                    ? () => _save(context, controller, state)
                    : null,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _save(
    BuildContext context,
    ResponseController controller,
    ResponseState state,
  ) async {
    final r = (state as ResponseSuccess).response;
    final name = await promptDialog(
      context,
      title: 'Save as example',
      initial: '${r.statusCode} ${r.statusMessage}'.trim(),
    );
    if (name == null || !context.mounted) return;
    await guarded(
      context,
      () => controller.saveExample(name: name),
      success: 'Example saved',
    );
  }

  Future<void> _rename(
    BuildContext context,
    ResponseController controller,
    SavedResponse example,
  ) async {
    final name = await promptDialog(
      context,
      title: 'Rename example',
      initial: example.name,
      confirmLabel: 'Rename',
    );
    if (name == null || !context.mounted) return;
    await guarded(context, () async {
      await controller.renameExample(example.id, name);
      controller.viewExample(example.copyWith(name: name.trim()));
    });
  }

  Future<void> _delete(
    BuildContext context,
    ResponseController controller,
    SavedResponse example,
  ) async {
    final ok = await confirmDialog(
      context,
      title: 'Delete example',
      message: 'Delete "${example.name}"? This cannot be undone.',
    );
    if (!ok || !context.mounted) return;
    await guarded(context, () => controller.deleteExample(example.id));
  }
}
