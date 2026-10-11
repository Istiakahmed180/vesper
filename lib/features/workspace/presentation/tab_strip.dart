import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/platform_keys.dart';
import '../../../shared/widgets/method_badge.dart';
import '../../collections/presentation/collection_providers.dart';
import '../../environments/presentation/environment_providers.dart';
import '../../environments/presentation/environments_panel.dart';
import '../domain/workspace_models.dart';
import 'response_controller.dart';
import 'workspace_actions.dart';
import 'workspace_controller.dart';

class TabStrip extends ConsumerWidget {
  const TabStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final tabs = ref.watch(workspaceProvider.select((s) => s.tabs));
    final activeId = ref.watch(activeTabIdProvider);
    final actions = WorkspaceActions(ref, context);

    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: colors.sidebar,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: ReorderableListView.builder(
              // Tabs are cheap; keeping all of them built lets the active tab
              // be scrolled into view even when it is far off-screen.
              scrollCacheExtent: const ScrollCacheExtent.pixels(100000),
              scrollDirection: Axis.horizontal,
              buildDefaultDragHandles: false,
              itemCount: tabs.length,
              onReorderItem: (from, to) =>
                  ref.read(workspaceProvider.notifier).moveTab(from, to),
              proxyDecorator: (child, _, _) =>
                  Material(color: Colors.transparent, child: child),
              itemBuilder: (context, i) {
                final tab = tabs[i];
                return ReorderableDragStartListener(
                  key: ValueKey(tab.id),
                  index: i,
                  child: _TabItem(
                    tab: tab,
                    active: tab.id == activeId,
                    actions: actions,
                  ),
                );
              },
            ),
          ),
          Tooltip(
            message: 'New tab (${PlatformKeys.combo('T')})',
            child: IconButton(
              onPressed: actions.newTab,
              icon: const Icon(Icons.add),
            ),
          ),
          const SizedBox(width: 8),
          const EnvironmentSelector(),
          const SizedBox(width: 10),
        ],
      ),
    );
  }
}

class _TabItem extends ConsumerStatefulWidget {
  const _TabItem({
    required this.tab,
    required this.active,
    required this.actions,
  });
  final WorkspaceTab tab;
  final bool active;
  final WorkspaceActions actions;

  @override
  ConsumerState<_TabItem> createState() => _TabItemState();
}

class _TabItemState extends ConsumerState<_TabItem> {
  bool _hover = false;
  final _menu = MenuController();

  @override
  void initState() {
    super.initState();
    if (widget.active) _revealSoon();
  }

  @override
  void didUpdateWidget(_TabItem old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _revealSoon();
  }

  /// Keeps the active tab visible when it is opened or selected. Jumps (no
  /// animation) so the tab is never mid-scroll when the user clicks it.
  void _revealSoon() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    for (final policy in [
      ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      ScrollPositionAlignmentPolicy.keepVisibleAtStart,
    ]) {
      Scrollable.ensureVisible(context, alignmentPolicy: policy);
    }
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tab = widget.tab;
    final loading = ref.watch(
      responseProvider(tab.id).select((s) => s is ResponseLoading),
    );
    final title = switch (tab) {
      RequestTab() => tab.title,
      EnvironmentTab(:final environmentId, :final name) =>
        ref.watch(
              environmentsProvider.select(
                (e) => e.value
                    ?.where((x) => x.id == environmentId)
                    .firstOrNull
                    ?.name,
              ),
            ) ??
            name,
      CollectionTab(:final collectionId, :final name) =>
        ref.watch(
              collectionTreesProvider.select(
                (t) => t.value
                    ?.where((x) => x.collection.id == collectionId)
                    .firstOrNull
                    ?.collection
                    .name,
              ),
            ) ??
            name,
    };

    return MenuAnchor(
      controller: _menu,
      menuChildren: [
        MenuItemButton(
          onPressed: () => widget.actions.closeTab(tab.id),
          child: const Text('Close'),
        ),
        MenuItemButton(
          onPressed: () =>
              ref.read(workspaceProvider.notifier).closeOtherTabs(tab.id),
          child: const Text('Close other tabs'),
        ),
        if (tab is RequestTab)
          MenuItemButton(
            onPressed: () => widget.actions.duplicateTab(tab.id),
            child: const Text('Duplicate'),
          ),
      ],
      child: Listener(
        onPointerDown: (e) {
          if (e.buttons == kMiddleMouseButton) widget.actions.closeTab(tab.id);
        },
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: () => ref.read(workspaceProvider.notifier).activate(tab.id),
            onSecondaryTapUp: (d) => _menu.open(position: d.localPosition),
            child: Container(
              constraints: const BoxConstraints(minWidth: 120, maxWidth: 220),
              padding: const EdgeInsets.only(left: 12, right: 4),
              decoration: BoxDecoration(
                color: widget.active
                    ? colors.panel
                    : (_hover ? colors.hover : Colors.transparent),
                border: Border(
                  top: BorderSide(
                    color: widget.active ? colors.accent : Colors.transparent,
                    width: 2,
                  ),
                  right: BorderSide(color: colors.border),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (tab is RequestTab)
                    MethodBadge(tab.draft.method, width: 38, fontSize: 10)
                  else
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(
                        tab is CollectionTab
                            ? Icons.folder_copy_outlined
                            : Icons.layers_outlined,
                        size: 14,
                        color: colors.textSecondary,
                      ),
                    ),
                  Flexible(
                    child: Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: widget.active
                            ? colors.textPrimary
                            : colors.textSecondary,
                        fontStyle: tab is RequestTab && !tab.isSaved
                            ? FontStyle.italic
                            : FontStyle.normal,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  SizedBox(
                    width: 22,
                    height: 22,
                    child: loading
                        ? const Padding(
                            padding: EdgeInsets.all(5),
                            child: CircularProgressIndicator(strokeWidth: 1.5),
                          )
                        : (_hover || widget.active || !tab.isDirty)
                        ? (_hover || widget.active
                              ? IconButton(
                                  padding: EdgeInsets.zero,
                                  iconSize: 14,
                                  tooltip: 'Close (${PlatformKeys.combo('W')})',
                                  onPressed: () =>
                                      widget.actions.closeTab(tab.id),
                                  icon: Icon(
                                    tab.isDirty && !_hover
                                        ? Icons.circle
                                        : Icons.close,
                                    size: tab.isDirty && !_hover ? 8 : 14,
                                  ),
                                )
                              : null)
                        : Center(
                            child: Icon(
                              Icons.circle,
                              size: 8,
                              color: colors.textSecondary,
                            ),
                          ),
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
