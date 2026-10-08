import 'package:flutter/material.dart';

import '../../core/errors/app_failure.dart';
import '../../core/theme/app_colors.dart';

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Delete',
  bool destructive = true,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) {
      final colors = context.colors;
      return AlertDialog(
        title: Text(title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Text(
            message,
            style: TextStyle(color: colors.textSecondary, fontSize: 13),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            autofocus: true,
            style: destructive
                ? FilledButton.styleFrom(backgroundColor: colors.danger)
                : null,
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  return result ?? false;
}

/// Three-way choice used when closing tabs with unsaved changes.
enum UnsavedChoice { save, discard, cancel }

Future<UnsavedChoice> unsavedChangesDialog(
  BuildContext context,
  String name,
) async {
  final result = await showDialog<UnsavedChoice>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Unsaved changes'),
      content: Text(
        '"$name" has unsaved changes. Do you want to save them?',
        style: TextStyle(color: context.colors.textSecondary, fontSize: 13),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, UnsavedChoice.discard),
          child: const Text("Don't save"),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, UnsavedChoice.cancel),
          child: const Text('Cancel'),
        ),
        FilledButton(
          autofocus: true,
          onPressed: () => Navigator.pop(context, UnsavedChoice.save),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  return result ?? UnsavedChoice.cancel;
}

Future<String?> promptDialog(
  BuildContext context, {
  required String title,
  String initial = '',
  String label = 'Name',
  String confirmLabel = 'Save',
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _PromptDialog(
      title: title,
      initial: initial,
      label: label,
      confirmLabel: confirmLabel,
    ),
  );
}

class _PromptDialog extends StatefulWidget {
  const _PromptDialog({
    required this.title,
    required this.initial,
    required this.label,
    required this.confirmLabel,
  });

  final String title;
  final String initial;
  final String label;
  final String confirmLabel;

  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  late final _controller = TextEditingController(text: widget.initial)
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initial.length,
    );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _controller.text.trim();
    if (v.isNotEmpty) Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 380,
      child: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(labelText: widget.label),
        onSubmitted: (_) => _submit(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
    ],
  );
}

void showToast(BuildContext context, String message, {bool error = false}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final colors = context.colors;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        duration: Duration(seconds: error ? 5 : 2),
        content: Row(
          children: [
            Icon(
              error ? Icons.error_outline : Icons.check_circle_outline,
              size: 16,
              color: error ? colors.danger : colors.success,
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
}

/// Runs [action], showing a readable error toast on failure.
Future<T?> guarded<T>(
  BuildContext context,
  Future<T> Function() action, {
  String? success,
}) async {
  try {
    final result = await action();
    if (success != null && context.mounted) showToast(context, success);
    return result;
  } catch (e) {
    if (context.mounted) showToast(context, e.userMessage, error: true);
    return null;
  }
}
