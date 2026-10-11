import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/platform_keys.dart';
import '../../../shared/widgets/dialogs.dart';
import '../../../shared/widgets/section_tabs.dart';
import '../../../shared/widgets/variable_scope.dart';
import '../../api_client/domain/models/request_auth.dart';
import '../../api_client/presentation/request/auth_editor.dart';
import '../../environments/domain/environment_models.dart';
import '../../environments/presentation/variable_table.dart';
import '../../workspace/domain/workspace_models.dart';
import '../../workspace/presentation/workspace_controller.dart';
import '../domain/collection_models.dart';
import 'collection_providers.dart';

/// Collection authorization and variables. Edits are local until saved.
class CollectionEditor extends ConsumerStatefulWidget {
  const CollectionEditor({super.key, required this.tabId});
  final String tabId;

  @override
  ConsumerState<CollectionEditor> createState() => _CollectionEditorState();
}

class _CollectionEditorState extends ConsumerState<CollectionEditor> {
  CollectionSettings? _original;
  RequestAuth _auth = const NoAuth();
  List<EnvVariable> _vars = [];
  bool _saving = false;

  CollectionSettings get _draft =>
      CollectionSettings(auth: _auth, variables: _vars);

  bool get _dirty => _original != null && _draft != _original;

  void _load(CollectionSettings settings) {
    _original = settings;
    _auth = settings.auth;
    _vars = [...settings.variables];
  }

  Future<void> _save(String collectionId) async {
    if (!_dirty) return;
    setState(() => _saving = true);
    await guarded(
      context,
      () => ref
          .read(collectionRepositoryProvider)
          .saveSettings(collectionId, _draft),
      success: 'Collection saved',
    );
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tab = ref.watch(
      workspaceProvider.select((s) {
        final t = s.tab(widget.tabId);
        return t is CollectionTab ? t : null;
      }),
    );
    if (tab == null) return const SizedBox.shrink();
    final id = tab.collectionId;
    final trees = ref.watch(collectionTreesProvider).value;
    final tree = trees?.where((t) => t.collection.id == id).firstOrNull;
    final settings = ref.watch(collectionSettingsProvider(id));
    if ((trees != null && tree == null) ||
        (settings.hasValue && settings.value == null)) {
      return const EmptyState(
        icon: Icons.delete_outline,
        title: 'This collection was deleted',
      );
    }
    final loaded = settings.value;
    if (tree == null || loaded == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    // Pick up external changes (e.g. after save) only when not editing.
    if (_original == null || (!_dirty && _original != loaded)) _load(loaded);

    final variableCount = _vars.where((v) => v.isActive).length;
    final section = tab.section;

    return CallbackShortcuts(
      bindings: {
        SingleActivator(
          LogicalKeyboardKey.keyS,
          meta: PlatformKeys.isMac,
          control: !PlatformKeys.isMac,
        ): () =>
            _save(id),
      },
      child: VariableScope(
        collectionId: id,
        child: ColoredBox(
          color: colors.panel,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 16, 10),
                child: Row(
                  children: [
                    Icon(
                      Icons.folder_copy_outlined,
                      size: 20,
                      color: colors.accent,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tree.collection.name,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text(
                            'Shared by every request in this collection. '
                            'Requests set to "Inherit auth from parent" use this '
                            'authorization.',
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    FilledButton(
                      key: const ValueKey('save-collection'),
                      onPressed: _dirty && !_saving ? () => _save(id) : null,
                      child: Text(_dirty ? 'Save' : 'Saved'),
                    ),
                  ],
                ),
              ),
              SectionTabs(
                tabs: [
                  SectionTab('Authorization', dot: _auth is! NoAuth),
                  SectionTab(
                    'Variables',
                    badge: variableCount == 0 ? null : '$variableCount',
                  ),
                ],
                selected: section.index,
                onSelected: (i) => ref
                    .read(workspaceProvider.notifier)
                    .setCollectionSection(
                      widget.tabId,
                      CollectionSection.values[i],
                    ),
              ),
              Expanded(
                child: switch (section) {
                  CollectionSection.authorization => AuthForm(
                    auth: _auth,
                    onChanged: (a) => setState(() => _auth = a),
                    noAuthHint:
                        'Requests in this collection that inherit their '
                        'authorization send none.',
                  ),
                  CollectionSection.variables => VariableTable(
                    variables: _vars,
                    onChanged: (vars) => setState(() => _vars = vars),
                    footer:
                        'Use collection variables as {{name}} in the requests of '
                        'this collection. The active environment overrides a '
                        'variable with the same name; collection values override '
                        'Globals. Secret values are stored encrypted on this computer.',
                  ),
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
