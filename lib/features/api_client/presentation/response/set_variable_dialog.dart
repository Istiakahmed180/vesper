import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/dialogs.dart';
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
  ExtractionTarget? _target;
  bool _saving = false;

  static final _validName = RegExp(r'^[^\s{}]+$');

  @override
  void dispose() {
    _name.dispose();
    _value.dispose();
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
    final hasCollection = _collectionId != null;

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

    return AlertDialog(
      title: const Text('Set as variable'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('set-variable-name'),
              controller: _name,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Variable name',
                helperText: nameOk ? 'Use it as {{$name}}' : null,
                errorText: name.isNotEmpty && !nameOk
                    ? 'No spaces or braces'
                    : null,
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => canSave ? _save(target) : null,
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
              'An existing variable with this name is overwritten.',
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
