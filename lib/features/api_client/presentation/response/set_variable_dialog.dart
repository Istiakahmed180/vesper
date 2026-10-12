import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/dialogs.dart';
import '../../../../core/security/redactor.dart';
import '../../../collections/presentation/collection_providers.dart';
import '../../../environments/domain/environment_models.dart';
import '../../../environments/presentation/environment_providers.dart';
import '../../../workspace/domain/workspace_models.dart';
import '../../../workspace/presentation/variable_updater.dart';
import '../../../workspace/presentation/workspace_controller.dart';
import '../../domain/models/variable_extraction.dart';

/// Context-menu entry that stores [value] (usually selected response text)
/// as a variable. Null when there is nothing to store.
ContextMenuButtonItem? setVariableMenuItem(
  BuildContext context,
  WidgetRef ref, {
  required String tabId,
  required String value,
  String name = '',
}) {
  if (value.trim().isEmpty) return null;
  return ContextMenuButtonItem(
    label: 'Set as variable…',
    onPressed: () {
      ContextMenuController.removeAny();
      showSetVariableDialog(
        context,
        ref,
        tabId: tabId,
        value: value,
        name: name,
      );
    },
  );
}

/// Asks for a variable name and scope, then saves [value] into the active
/// environment, the request's collection or the Globals.
Future<void> showSetVariableDialog(
  BuildContext context,
  WidgetRef ref, {
  required String tabId,
  required String value,
  String name = '',
}) => showDialog<void>(
  context: context,
  builder: (_) =>
      _SetVariableDialog(tabId: tabId, value: _unquote(value), name: name),
);

/// Trims [value] and drops the quotes around a selected JSON string.
String _unquote(String value) {
  final v = value.trim();
  return v.length >= 2 && v.startsWith('"') && v.endsWith('"')
      ? v.substring(1, v.length - 1)
      : v;
}

class _SetVariableDialog extends ConsumerStatefulWidget {
  const _SetVariableDialog({
    required this.tabId,
    required this.value,
    required this.name,
  });

  final String tabId;
  final String value;
  final String name;

  @override
  ConsumerState<_SetVariableDialog> createState() => _SetVariableDialogState();
}

class _SetVariableDialogState extends ConsumerState<_SetVariableDialog> {
  late final _name = TextEditingController(text: widget.name);
  late final _value = TextEditingController(text: widget.value);
  final _nameFocus = FocusNode();
  ExtractionTarget? _target;
  bool _saving = false;

  static final _validName = RegExp(r'^[^\s{}]+$');

  @override
  void dispose() {
    _name.dispose();
    _value.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  String? get _collectionId => ref
      .read(workspaceProvider)
      .tabs
      .whereType<RequestTab>()
      .where((t) => t.id == widget.tabId)
      .firstOrNull
      ?.draft
      .collectionId;

  Future<void> _save(ExtractionTarget target) async {
    final name = _name.text.trim();
    if (!_validName.hasMatch(name)) return;
    setState(() => _saving = true);
    final note = await guarded(
      context,
      () => setVariables(ref.read, target, _collectionId, {name: _value.text}),
    );
    if (!mounted) return;
    if (note == null) {
      setState(() => _saving = false);
      return;
    }
    showToast(context, note.message, error: !note.ok);
    if (note.ok) {
      Navigator.pop(context);
    } else {
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final active = ref.watch(activeEnvironmentProvider);
    final globals = ref.watch(globalsEnvironmentProvider);
    final collectionId = _collectionId;
    final hasCollection = collectionId != null;

    String label(ExtractionTarget t) => switch (t) {
      ExtractionTarget.environment =>
        active == null
            ? 'Active environment (none selected)'
            : 'Environment: ${active.name}',
      ExtractionTarget.collection =>
        hasCollection ? 'Collection' : 'Collection (request not saved)',
      ExtractionTarget.globals => 'Globals',
    };
    bool enabled(ExtractionTarget t) => switch (t) {
      ExtractionTarget.environment => active != null,
      ExtractionTarget.collection => hasCollection,
      ExtractionTarget.globals => globals != null,
    };
    final target =
        _target ??
        ExtractionTarget.values.where(enabled).firstOrNull ??
        ExtractionTarget.environment;
    final name = _name.text.trim();
    final nameOk = _validName.hasMatch(name);
    final canSave = !_saving && nameOk && enabled(target);

    // Variables already in the chosen scope, offered as name suggestions.
    final existing = (switch (target) {
      ExtractionTarget.environment => active?.variables,
      ExtractionTarget.globals => globals?.variables,
      ExtractionTarget.collection =>
        collectionId == null
            ? null
            : ref
                  .watch(collectionSettingsProvider(collectionId))
                  .value
                  ?.variables,
    }) ?? const <EnvVariable>[];
    final names = [
      for (final v in existing)
        if (v.key.trim().isNotEmpty) v,
    ];
    final overwrites = names.any((v) => v.key == name);

    return AlertDialog(
      title: const Text('Set as variable'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Free text, with the scope's existing names as suggestions.
            RawAutocomplete<EnvVariable>(
              textEditingController: _name,
              focusNode: _nameFocus,
              displayStringForOption: (v) => v.key,
              optionsBuilder: (value) {
                final q = value.text.trim().toLowerCase();
                return names
                    .where(
                      (v) =>
                          v.key.toLowerCase().contains(q) &&
                          v.key != value.text.trim(),
                    )
                    .take(8);
              },
              onSelected: (_) => setState(() {}),
              fieldViewBuilder: (context, controller, focusNode, submit) =>
                  TextField(
                    key: const ValueKey('set-variable-name'),
                    controller: controller,
                    focusNode: focusNode,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: 'Variable name',
                      hintText: names.isEmpty
                          ? null
                          : 'New name, or pick an existing one',
                      helperText: !nameOk
                          ? null
                          : overwrites
                          ? 'Replaces the current value of {{$name}}'
                          : 'Creates {{$name}}',
                      errorText: name.isNotEmpty && !nameOk
                          ? 'No spaces or braces'
                          : null,
                    ),
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => canSave ? _save(target) : null,
                  ),
              optionsViewBuilder: (context, onSelected, options) => Align(
                alignment: Alignment.topLeft,
                child: Material(
                  elevation: 8,
                  color: colors.panelRaised,
                  borderRadius: BorderRadius.circular(6),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: 440,
                      maxHeight: 240,
                    ),
                    child: ListView(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      shrinkWrap: true,
                      children: [
                        for (final v in options)
                          InkWell(
                            key: ValueKey('set-variable-option-${v.key}'),
                            onTap: () => onSelected(v),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 7,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      v.key,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: colors.variable,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Flexible(
                                    child: Text(
                                      v.isSecret ? Redactor.mask : v.value,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: colors.textMuted,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _value,
              minLines: 1,
              maxLines: 5,
              decoration: const InputDecoration(labelText: 'Value'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<ExtractionTarget>(
              key: const ValueKey('set-variable-target'),
              initialValue: target,
              isDense: true,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Save to'),
              items: [
                for (final t in ExtractionTarget.values)
                  DropdownMenuItem(
                    value: t,
                    enabled: enabled(t),
                    child: Text(
                      label(t),
                      overflow: TextOverflow.ellipsis,
                      style: enabled(t)
                          ? null
                          : TextStyle(color: colors.textMuted),
                    ),
                  ),
              ],
              onChanged: (t) => setState(() => _target = t),
            ),
            const SizedBox(height: 8),
            Text(
              'Click the name field to see the variables already in this '
              'scope.',
              style: TextStyle(fontSize: 12, color: colors.textMuted),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('set-variable-save'),
          onPressed: canSave ? () => _save(target) : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
