import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/security/redactor.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/dialogs.dart';
import '../../workspace/presentation/workspace_controller.dart';
import '../domain/environment_models.dart';
import '../domain/environment_repository.dart';
import 'environment_providers.dart';

/// Eye button next to the environment selector: shows the variables of the
/// active environment and the Globals, and lets you add or change them
/// without leaving the request.
class EnvironmentQuickLook extends StatefulWidget {
  const EnvironmentQuickLook({super.key});

  @override
  State<EnvironmentQuickLook> createState() => _EnvironmentQuickLookState();
}

class _EnvironmentQuickLookState extends State<EnvironmentQuickLook> {
  final _link = LayerLink();
  final _portal = OverlayPortalController();

  void _toggle() => setState(_portal.toggle);

  void _close() {
    if (_portal.isShowing) setState(_portal.hide);
  }

  @override
  Widget build(BuildContext context) => OverlayPortal(
    controller: _portal,
    overlayChildBuilder: (_) => CompositedTransformFollower(
      link: _link,
      targetAnchor: Alignment.bottomRight,
      followerAnchor: Alignment.topRight,
      offset: const Offset(0, 6),
      child: Align(
        alignment: Alignment.topRight,
        child: TapRegion(
          groupId: _link,
          onTapOutside: (_) => _close(),
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): _close,
            },
            child: _QuickLookPanel(onClose: _close),
          ),
        ),
      ),
    ),
    child: CompositedTransformTarget(
      link: _link,
      child: TapRegion(
        groupId: _link,
        child: IconButton(
          key: const ValueKey('environment-quick-look'),
          tooltip: 'Environment quick look',
          isSelected: _portal.isShowing,
          onPressed: _toggle,
          icon: const Icon(Icons.visibility_outlined, size: 18),
        ),
      ),
    ),
  );
}

class _QuickLookPanel extends ConsumerWidget {
  const _QuickLookPanel({required this.onClose});
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final active = ref.watch(activeEnvironmentProvider);
    final globals = ref.watch(globalsEnvironmentProvider);

    void edit(Environment env) {
      onClose();
      ref.read(workspaceProvider.notifier).openEnvironment(env.id, env.name);
    }

    return Material(
      color: colors.panelRaised,
      elevation: 10,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: colors.borderStrong),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 560),
        child: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (active == null)
                  const _Section(
                    title: 'No environment selected',
                    subtitle:
                        'Choose one in the menu next to this button to use '
                        'its variables.',
                    child: SizedBox.shrink(),
                  )
                else
                  _Section(
                    title: active.name,
                    subtitle: 'Active environment',
                    onEdit: () => edit(active),
                    child: _VariableList(
                      key: ValueKey('quick-${active.id}'),
                      environment: active,
                    ),
                  ),
                const SizedBox(height: 14),
                Divider(height: 1, color: colors.border),
                const SizedBox(height: 12),
                if (globals != null)
                  _Section(
                    title: 'Globals',
                    subtitle:
                        'Available in every request; the active environment '
                        'overrides them.',
                    onEdit: () => edit(globals),
                    child: _VariableList(
                      key: ValueKey('quick-${globals.id}'),
                      environment: globals,
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

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.subtitle,
    required this.child,
    this.onEdit,
  });

  final String title;
  final String subtitle;
  final Widget child;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 11.5, color: colors.textMuted),
                  ),
                ],
              ),
            ),
            if (onEdit != null)
              TextButton(onPressed: onEdit, child: const Text('Edit')),
          ],
        ),
        const SizedBox(height: 6),
        child,
      ],
    );
  }
}

/// The variables of one environment, editable in place, plus a row to add
/// a variable. Changes are saved on Enter, when a field loses focus and when
/// the panel closes, so typed values are never dropped.
class _VariableList extends ConsumerStatefulWidget {
  const _VariableList({super.key, required this.environment});
  final Environment environment;

  @override
  ConsumerState<_VariableList> createState() => _VariableListState();
}

class _VariableListState extends ConsumerState<_VariableList> {
  final _newKey = TextEditingController();
  final _newValue = TextEditingController();
  final _newKeyFocus = FocusNode();

  /// Captured up front: [ref] can no longer be used once the panel closes,
  /// which is exactly when the last edits are flushed.
  late final EnvironmentRepository _repo;

  /// Edited values not saved yet, by variable id.
  final _drafts = <String, String>{};

  /// What was last saved, until the stream delivers it as
  /// [widget.environment]; keeps quick successive saves from undoing each
  /// other.
  Environment? _saved;

  Environment get _base => _saved ?? widget.environment;

  @override
  void initState() {
    super.initState();
    _repo = ref.read(environmentRepositoryProvider);
  }

  @override
  void didUpdateWidget(_VariableList old) {
    super.didUpdateWidget(old);
    if (!identical(old.environment, widget.environment)) _saved = null;
  }

  @override
  void dispose() {
    _flush(includeNew: true);
    _newKey.dispose();
    _newValue.dispose();
    _newKeyFocus.dispose();
    super.dispose();
  }

  /// Saves pending value edits (and the new-variable row when
  /// [includeNew]), optionally dropping [removeId], in one write.
  Future<void> _flush({bool includeNew = false, String? removeId}) async {
    final base = _base;
    final key = _newKey.text.trim();
    final addNew = includeNew && key.isNotEmpty;
    if (_drafts.isEmpty && !addNew && removeId == null) return;

    var vars = [
      for (final v in base.variables)
        if (v.id != removeId)
          _drafts.containsKey(v.id) ? v.copyWith(value: _drafts[v.id]) : v,
    ];
    _drafts.clear();
    if (addNew) {
      final value = _newValue.text;
      final existing = vars.where((v) => v.key == key).firstOrNull;
      vars = existing == null
          ? [
              ...vars,
              EnvVariable(
                key: key,
                value: value,
                isSecret: Redactor.isSensitiveKey(key),
              ),
            ]
          : [for (final v in vars) v.key == key ? v.copyWith(value: value) : v];
      _newKey.clear();
      _newValue.clear();
    }

    final updated = base.copyWith(variables: vars);
    _saved = updated;
    if (mounted) {
      await guarded(context, () => _repo.saveEnvironment(updated));
    } else {
      // Panel already closed: nowhere to show an error.
      await _repo.saveEnvironment(updated).catchError((_) {});
    }
  }

  Future<void> _add() async {
    if (_newKey.text.trim().isEmpty) return;
    await _flush(includeNew: true);
    if (mounted) _newKeyFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final mono = AppTheme.mono(context, size: 12.5);
    final vars = _base.variables;
    InputDecoration deco(String hint) => InputDecoration(
      hintText: hint,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (vars.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              'No variables yet.',
              style: TextStyle(fontSize: 12, color: colors.textMuted),
            ),
          ),
        for (final v in vars)
          _VariableRow(
            key: ValueKey(v.id),
            variable: v,
            onDraft: (value) {
              if (value == v.value) {
                _drafts.remove(v.id);
              } else {
                _drafts[v.id] = value;
              }
            },
            onCommit: _flush,
            onRemove: () => _flush(removeId: v.id),
          ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              flex: 2,
              child: TextField(
                key: const ValueKey('quick-new-key'),
                controller: _newKey,
                focusNode: _newKeyFocus,
                style: mono.copyWith(color: colors.variable),
                decoration: deco('new_variable'),
                onSubmitted: (_) => _add(),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              flex: 3,
              child: TextField(
                key: const ValueKey('quick-new-value'),
                controller: _newValue,
                style: mono,
                decoration: deco('value'),
                onSubmitted: (_) => _add(),
              ),
            ),
            const SizedBox(width: 6),
            IconButton(
              key: const ValueKey('quick-add'),
              tooltip: 'Add variable',
              onPressed: _add,
              icon: const Icon(Icons.add, size: 18),
            ),
          ],
        ),
      ],
    );
  }
}

class _VariableRow extends StatefulWidget {
  const _VariableRow({
    super.key,
    required this.variable,
    required this.onDraft,
    required this.onCommit,
    required this.onRemove,
  });

  final EnvVariable variable;

  /// Reports every edit so the list can save it even if the panel closes.
  final ValueChanged<String> onDraft;
  final VoidCallback onCommit;
  final VoidCallback onRemove;

  @override
  State<_VariableRow> createState() => _VariableRowState();
}

class _VariableRowState extends State<_VariableRow> {
  late final _value = TextEditingController(text: widget.variable.value);
  final _focus = FocusNode();
  bool _revealed = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && mounted) widget.onCommit();
    });
  }

  @override
  void didUpdateWidget(_VariableRow old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && widget.variable.value != _value.text) {
      _value.text = widget.variable.value;
    }
  }

  @override
  void dispose() {
    _value.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final v = widget.variable;
    final mono = AppTheme.mono(context, size: 12.5);
    return Opacity(
      opacity: v.enabled ? 1 : 0.5,
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                v.key,
                overflow: TextOverflow.ellipsis,
                style: mono.copyWith(color: colors.variable),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            flex: 3,
            child: TextField(
              controller: _value,
              focusNode: _focus,
              obscureText: v.isSecret && !_revealed,
              style: mono,
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
              ),
              onChanged: widget.onDraft,
              onSubmitted: (_) => widget.onCommit(),
            ),
          ),
          SizedBox(
            width: 36,
            child: v.isSecret
                ? IconButton(
                    tooltip: _revealed ? 'Hide' : 'Reveal',
                    iconSize: 15,
                    onPressed: () => setState(() => _revealed = !_revealed),
                    icon: Icon(
                      _revealed
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                  )
                : null,
          ),
          IconButton(
            tooltip: 'Remove',
            iconSize: 15,
            onPressed: widget.onRemove,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}
