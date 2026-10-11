import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/security/redactor.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/key_value_editor.dart';
import '../../../../shared/widgets/section_tabs.dart';
import '../../../../shared/widgets/split_view.dart';
import '../../../../shared/widgets/variable_scope.dart';
import '../../../collections/presentation/collection_providers.dart';
import '../../../environments/presentation/environment_providers.dart';
import '../../../workspace/presentation/workspace_controller.dart';
import '../../domain/models/request_auth.dart';
import '../../domain/models/request_body.dart';
import '../../domain/services/variable_resolver.dart';
import '../response/response_panel.dart';
import 'auth_editor.dart';
import 'body_editor.dart';
import 'cookies_view.dart';
import 'request_options_view.dart';
import 'url_bar.dart';

/// Selected request section per tab, kept across tab switches.
final editorSectionProvider =
    NotifierProvider.family<EditorSection, int, String>(EditorSection.new);

class EditorSection extends Notifier<int> {
  EditorSection(this.tabId);
  final String tabId;

  @override
  int build() => 0;
  void select(int i) => state = i;
}

/// Request builder (top) and response viewer (bottom) for one tab.
class RequestWorkspace extends ConsumerWidget {
  const RequestWorkspace({super.key, required this.tabId});
  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => VariableScope(
    // Saved requests also see their collection's variables.
    collectionId: ref.watch(
      requestTabProvider(tabId).select((t) => t?.draft.collectionId),
    ),
    child: SplitView(
      axis: Axis.vertical,
      initialFraction: 0.48,
      minFirst: 170,
      minSecond: 140,
      first: RequestEditor(tabId: tabId),
      second: ResponsePanel(tabId: tabId),
    ),
  );
}

class RequestEditor extends ConsumerWidget {
  const RequestEditor({super.key, required this.tabId});
  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final section = ref.watch(editorSectionProvider(tabId));
    final paramCount = ref.watch(
      requestTabProvider(
        tabId,
      ).select((t) => t?.draft.params.where((p) => p.isActive).length ?? 0),
    );
    final headerCount = ref.watch(
      requestTabProvider(
        tabId,
      ).select((t) => t?.draft.headers.where((h) => h.isActive).length ?? 0),
    );
    final hasAuth = ref.watch(
      requestTabProvider(
        tabId,
      ).select((t) => t != null && t.draft.auth is! NoAuth),
    );
    final hasBody = ref.watch(
      requestTabProvider(
        tabId,
      ).select((t) => t != null && t.draft.body.type != BodyType.none),
    );
    final notice = ref.watch(
      requestTabProvider(tabId).select((t) => t?.notice),
    );

    return ColoredBox(
      color: colors.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (notice != null)
            Container(
              color: colors.info.withValues(alpha: 0.1),
              padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 15, color: colors.info),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      notice,
                      style: TextStyle(fontSize: 12, color: colors.textPrimary),
                    ),
                  ),
                  IconButton(
                    onPressed: () => ref
                        .read(workspaceProvider.notifier)
                        .dismissNotice(tabId),
                    icon: const Icon(Icons.close, size: 14),
                  ),
                ],
              ),
            ),
          _Breadcrumb(tabId: tabId),
          UrlBar(tabId: tabId),
          _VariablePreview(tabId: tabId),
          SectionTabs(
            tabs: [
              SectionTab(
                'Params',
                badge: paramCount == 0 ? null : '$paramCount',
              ),
              SectionTab('Authorization', dot: hasAuth),
              SectionTab(
                'Headers',
                badge: headerCount == 0 ? null : '$headerCount',
              ),
              SectionTab('Body', dot: hasBody),
              const SectionTab('Cookies'),
              const SectionTab('Settings'),
            ],
            selected: section,
            onSelected: ref.read(editorSectionProvider(tabId).notifier).select,
          ),
          Expanded(
            child: switch (section) {
              0 => _ParamsSection(tabId: tabId),
              1 => AuthEditor(tabId: tabId),
              2 => _HeadersSection(tabId: tabId),
              3 => BodyEditor(tabId: tabId),
              4 => CookiesView(tabId: tabId),
              _ => RequestOptionsView(tabId: tabId),
            },
          ),
        ],
      ),
    );
  }
}

class _Breadcrumb extends ConsumerStatefulWidget {
  const _Breadcrumb({required this.tabId});
  final String tabId;

  @override
  ConsumerState<_Breadcrumb> createState() => _BreadcrumbState();
}

class _BreadcrumbState extends ConsumerState<_Breadcrumb> {
  bool _editing = false;
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && _editing) _commit();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit() {
    final name = _controller.text.trim();
    if (name.isNotEmpty) {
      ref
          .read(workspaceProvider.notifier)
          .updateDraft(widget.tabId, (d) => d.copyWith(name: name));
    }
    setState(() => _editing = false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final name =
        ref.watch(
          requestTabProvider(widget.tabId).select((t) => t?.draft.name),
        ) ??
        '';
    final location = ref.watch(
      requestTabProvider(widget.tabId).select(
        (t) => t?.baseline == null
            ? null
            : (t!.baseline!.collectionId, t.baseline!.folderId),
      ),
    );
    final trees = ref.watch(collectionTreesProvider).value ?? const [];
    final crumbs = <String>[];
    if (location != null) {
      final tree = trees
          .where((t) => t.collection.id == location.$1)
          .firstOrNull;
      if (tree != null) {
        crumbs.add(tree.collection.name);
        final folders = {for (final f in tree.allFolders) f.id: f};
        final chain = <String>[];
        var fid = location.$2;
        while (fid != null && folders[fid] != null && chain.length < 32) {
          chain.insert(0, folders[fid]!.name);
          fid = folders[fid]!.parentId;
        }
        crumbs.addAll(chain);
      }
    }

    final crumbStyle = TextStyle(fontSize: 12.5, color: colors.textMuted);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: SizedBox(
        height: 26,
        child: Row(
          children: [
            if (crumbs.isEmpty)
              Text('Unsaved request', style: crumbStyle)
            else
              for (final c in crumbs) ...[
                Flexible(
                  child: Text(
                    c,
                    style: crumbStyle,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text('/', style: crumbStyle),
                ),
              ],
            if (crumbs.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text('/', style: crumbStyle),
              ),
            if (_editing)
              SizedBox(
                width: 320,
                child: TextField(
                  controller: _controller,
                  focusNode: _focus,
                  autofocus: true,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  decoration: const InputDecoration(
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 4,
                    ),
                  ),
                  onSubmitted: (_) => _commit(),
                ),
              )
            else
              Flexible(
                flex: 2,
                child: Tooltip(
                  message: 'Click to rename',
                  child: InkWell(
                    onTap: () {
                      _controller.text = name;
                      _controller.selection = TextSelection(
                        baseOffset: 0,
                        extentOffset: name.length,
                      );
                      setState(() => _editing = true);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 2,
                        vertical: 3,
                      ),
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
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Chips showing how variables in the URL resolve (secrets masked).
class _VariablePreview extends ConsumerWidget {
  const _VariablePreview({required this.tabId});
  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url =
        ref.watch(requestTabProvider(tabId).select((t) => t?.draft.url)) ?? '';
    final names = VariableResolver.referencedNames(url).toSet().toList();
    if (names.isEmpty) return const SizedBox.shrink();
    final resolver = VariableScope.watch(ref, context);
    final env = ref.watch(activeEnvironmentProvider);
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (final name in names)
            Builder(
              builder: (context) {
                final v = resolver.lookup(name);
                final defined = v != null;
                final display = !defined
                    ? (env == null
                          ? 'not defined · no environment selected'
                          : 'not defined in ${env.name}')
                    : v.isSecret
                    ? Redactor.mask
                    : v.value;
                final color = defined
                    ? colors.variable
                    : colors.variableUnresolved;
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: color.withValues(alpha: 0.3)),
                  ),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: name,
                          style: TextStyle(
                            color: color,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        TextSpan(
                          text: '  →  ',
                          style: TextStyle(color: colors.textMuted),
                        ),
                        TextSpan(
                          text: display,
                          style: TextStyle(color: colors.textSecondary),
                        ),
                      ],
                    ),
                    style: AppTheme.mono(context, size: 11.5),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

class _ParamsSection extends ConsumerWidget {
  const _ParamsSection({required this.tabId});
  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final params =
        ref.watch(requestTabProvider(tabId).select((t) => t?.draft.params)) ??
        const [];
    return SingleChildScrollView(
      child: KeyValueEditor(
        rows: params,
        bulkSeparator: '=',
        keyHint: 'Parameter',
        onChanged: (rows) =>
            ref.read(workspaceProvider.notifier).setParams(tabId, rows),
      ),
    );
  }
}

class _HeadersSection extends ConsumerWidget {
  const _HeadersSection({required this.tabId});
  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final headers =
        ref.watch(requestTabProvider(tabId).select((t) => t?.draft.headers)) ??
        const [];
    final colors = context.colors;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KeyValueEditor(
            rows: headers,
            keyHint: 'Header',
            maskSensitive: true,
            onChanged: (rows) => ref
                .read(workspaceProvider.notifier)
                .updateDraft(tabId, (d) => d.copyWith(headers: rows)),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'Content-Type, User-Agent, Accept and authorization headers are added automatically '
              'unless you set them here.',
              style: TextStyle(fontSize: 11.5, color: colors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}
