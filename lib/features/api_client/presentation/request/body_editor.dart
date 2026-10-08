import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/utils/id.dart';
import '../../../../shared/widgets/code/code_editor.dart';
import '../../../../shared/widgets/dialogs.dart';
import '../../../../shared/widgets/key_value_editor.dart';
import '../../../../shared/widgets/section_tabs.dart';
import '../../../../shared/widgets/variable_field.dart';
import '../../../workspace/presentation/workspace_controller.dart';
import '../../domain/models/request_body.dart';
import '../response/body_formatter.dart';

class BodyEditor extends ConsumerWidget {
  const BodyEditor({super.key, required this.tabId});
  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final body =
        ref.watch(requestTabProvider(tabId).select((t) => t?.draft.body)) ??
        const RequestBody();
    final colors = context.colors;
    void set(RequestBody b) => ref
        .read(workspaceProvider.notifier)
        .updateDraft(tabId, (d) => d.copyWith(body: b));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: colors.border)),
          ),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final t in BodyType.values)
                        _BodyTypeOption(
                          label: t.label,
                          selected: body.type == t,
                          onTap: () => set(body.copyWith(type: t)),
                        ),
                    ],
                  ),
                ),
              ),
              if (body.type == BodyType.raw)
                SizedBox(
                  width: 130,
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<RawLanguage>(
                      value: body.rawLanguage,
                      isDense: true,
                      isExpanded: true,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: colors.textPrimary,
                      ),
                      items: [
                        for (final l in RawLanguage.values)
                          DropdownMenuItem(value: l, child: Text(l.label)),
                      ],
                      onChanged: (l) => set(body.copyWith(rawLanguage: l)),
                    ),
                  ),
                ),
              if (body.type == BodyType.json)
                _BeautifyButton(
                  text: body.text,
                  onChanged: (t) => set(body.copyWith(text: t)),
                ),
            ],
          ),
        ),
        Expanded(
          child: switch (body.type) {
            BodyType.none => const EmptyState(
              icon: Icons.block,
              title: 'This request has no body',
              message:
                  'Choose a body type above to send data with the request.',
            ),
            BodyType.json => _TextBody(
              key: const ValueKey('json'),
              text: body.text,
              language: CodeLanguage.json,
              validateJson: true,
              hint: '{\n  "name": "{{user_name}}"\n}',
              onChanged: (t) => set(body.copyWith(text: t)),
            ),
            BodyType.raw => _TextBody(
              key: const ValueKey('raw'),
              text: body.text,
              language: switch (body.rawLanguage) {
                RawLanguage.json => CodeLanguage.json,
                RawLanguage.xml => CodeLanguage.xml,
                RawLanguage.html => CodeLanguage.html,
                _ => CodeLanguage.text,
              },
              validateJson: false,
              onChanged: (t) => set(body.copyWith(text: t)),
            ),
            BodyType.urlEncoded => SingleChildScrollView(
              child: KeyValueEditor(
                rows: body.urlEncoded,
                bulkSeparator: '=',
                onChanged: (rows) => set(body.copyWith(urlEncoded: rows)),
              ),
            ),
            BodyType.formData => SingleChildScrollView(
              child: _FormDataEditor(
                fields: body.formData,
                onChanged: (f) => set(body.copyWith(formData: f)),
              ),
            ),
            BodyType.binary => _BinaryBody(
              path: body.binaryFilePath,
              onChanged: (path) =>
                  set(body.copyWith(binaryFilePath: () => path)),
            ),
          },
        ),
      ],
    );
  }
}

class _BodyTypeOption extends StatelessWidget {
  const _BodyTypeOption({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 14,
              color: selected ? colors.accent : colors.textMuted,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                color: selected ? colors.textPrimary : colors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BeautifyButton extends StatelessWidget {
  const _BeautifyButton({required this.text, required this.onChanged});
  final String text;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: () {
      try {
        onChanged(JsonTools.beautify(text));
      } on FormatException {
        showToast(
          context,
          'Cannot beautify: the body is not valid JSON.',
          error: true,
        );
      }
    },
    icon: const Icon(Icons.auto_fix_high, size: 15),
    label: const Text('Beautify'),
  );
}

class _TextBody extends StatefulWidget {
  const _TextBody({
    super.key,
    required this.text,
    required this.language,
    required this.validateJson,
    required this.onChanged,
    this.hint,
  });

  final String text;
  final CodeLanguage language;
  final bool validateJson;
  final ValueChanged<String> onChanged;
  final String? hint;

  @override
  State<_TextBody> createState() => _TextBodyState();
}

class _TextBodyState extends State<_TextBody> {
  String? _error;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _validate(widget.text);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _validate(String text) {
    if (!widget.validateJson || text.length > 1024 * 1024) return;
    final error = JsonTools.validate(text);
    if (error != _error) setState(() => _error = error);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: CodeEditor(
            value: widget.text,
            language: widget.language,
            hint: widget.hint,
            onChanged: (t) {
              widget.onChanged(t);
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 400), () {
                if (mounted) _validate(t);
              });
            },
          ),
        ),
        if (_error != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: colors.danger.withValues(alpha: 0.08),
            child: Row(
              children: [
                Icon(Icons.error_outline, size: 14, color: colors.danger),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _error!,
                    style: TextStyle(fontSize: 12, color: colors.danger),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _FormDataEditor extends StatefulWidget {
  const _FormDataEditor({required this.fields, required this.onChanged});
  final List<FormDataField> fields;
  final ValueChanged<List<FormDataField>> onChanged;

  @override
  State<_FormDataEditor> createState() => _FormDataEditorState();
}

class _FormDataEditorState extends State<_FormDataEditor> {
  String _ghostId = newId();

  void _update(FormDataField f) {
    if (widget.fields.any((e) => e.id == f.id)) {
      widget.onChanged([for (final e in widget.fields) e.id == f.id ? f : e]);
    } else {
      setState(() => _ghostId = newId());
      widget.onChanged([...widget.fields, f]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 28,
          margin: const EdgeInsets.only(top: 8),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: colors.border),
              bottom: BorderSide(color: colors.border),
            ),
          ),
          child: Row(
            children: [
              const SizedBox(width: 40),
              Expanded(
                flex: 2,
                child: Text(
                  'KEY',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              SizedBox(
                width: 78,
                child: Text(
                  'TYPE',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              Expanded(
                flex: 3,
                child: Text(
                  'VALUE',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              const SizedBox(width: 36),
            ],
          ),
        ),
        for (final f in widget.fields)
          _FormDataRow(
            key: ValueKey(f.id),
            field: f,
            onChanged: _update,
            onRemove: () => widget.onChanged(
              widget.fields.where((e) => e.id != f.id).toList(),
            ),
          ),
        _FormDataRow(
          key: ValueKey(_ghostId),
          field: FormDataField(id: _ghostId),
          ghost: true,
          onChanged: _update,
        ),
      ],
    );
  }
}

class _FormDataRow extends StatelessWidget {
  const _FormDataRow({
    super.key,
    required this.field,
    required this.onChanged,
    this.onRemove,
    this.ghost = false,
  });

  final FormDataField field;
  final ValueChanged<FormDataField> onChanged;
  final VoidCallback? onRemove;
  final bool ghost;

  Future<void> _pickFile(BuildContext context) async {
    final files = await FilePicker.pickFiles(
      dialogTitle: 'Choose a file to upload',
    );
    final path = files.firstOrNull?.path;
    if (path != null) {
      onChanged(
        field.copyWith(
          filePath: () => path,
          key: field.key.isEmpty ? p.basenameWithoutExtension(path) : null,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: colors.border.withValues(alpha: 0.6)),
        ),
      ),
      child: Opacity(
        opacity: !field.enabled && !ghost ? 0.5 : 1,
        child: Row(
          children: [
            SizedBox(
              width: 40,
              child: ghost
                  ? null
                  : Checkbox(
                      value: field.enabled,
                      onChanged: (v) =>
                          onChanged(field.copyWith(enabled: v ?? true)),
                    ),
            ),
            Expanded(
              flex: 2,
              child: VariableField(
                value: field.key,
                hint: 'Key',
                borderless: true,
                monospace: true,
                onChanged: (v) => onChanged(field.copyWith(key: v)),
              ),
            ),
            SizedBox(
              width: 78,
              child: DropdownButtonHideUnderline(
                child: DropdownButton<FormFieldKind>(
                  value: field.kind,
                  isDense: true,
                  style: TextStyle(fontSize: 12, color: colors.textSecondary),
                  items: const [
                    DropdownMenuItem(
                      value: FormFieldKind.text,
                      child: Text('Text'),
                    ),
                    DropdownMenuItem(
                      value: FormFieldKind.file,
                      child: Text('File'),
                    ),
                  ],
                  onChanged: (k) => onChanged(field.copyWith(kind: k)),
                ),
              ),
            ),
            Expanded(
              flex: 3,
              child: field.kind == FormFieldKind.text
                  ? VariableField(
                      value: field.value,
                      hint: 'Value',
                      borderless: true,
                      monospace: true,
                      onChanged: (v) => onChanged(field.copyWith(value: v)),
                    )
                  : Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              field.filePath == null
                                  ? 'No file selected'
                                  : p.basename(field.filePath!),
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12.5,
                                color: field.filePath == null
                                    ? colors.textMuted
                                    : colors.textPrimary,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: () => _pickFile(context),
                            child: const Text('Choose…'),
                          ),
                        ],
                      ),
                    ),
            ),
            SizedBox(
              width: 36,
              child: ghost
                  ? null
                  : IconButton(
                      tooltip: 'Remove',
                      iconSize: 15,
                      onPressed: onRemove,
                      icon: const Icon(Icons.close),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BinaryBody extends StatefulWidget {
  const _BinaryBody({required this.path, required this.onChanged});
  final String? path;
  final ValueChanged<String?> onChanged;

  @override
  State<_BinaryBody> createState() => _BinaryBodyState();
}

class _BinaryBodyState extends State<_BinaryBody> {
  bool _dragging = false;

  Future<void> _pick() async {
    final files = await FilePicker.pickFiles(
      dialogTitle: 'Choose a file to send',
    );
    final path = files.firstOrNull?.path;
    if (path != null) widget.onChanged(path);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final path = widget.path;
    final file = path == null ? null : File(path);
    final exists = file?.existsSync() ?? false;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) {
        setState(() => _dragging = false);
        final dropped = details.files.firstOrNull?.path;
        if (dropped != null) widget.onChanged(dropped);
      },
      child: Container(
        margin: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: _dragging ? colors.accent : colors.borderStrong,
            width: _dragging ? 2 : 1,
          ),
          color: _dragging ? colors.accentMuted.withValues(alpha: 0.3) : null,
        ),
        child: EmptyState(
          icon: Icons.upload_file_outlined,
          title: path == null
              ? 'Drop a file here or choose one'
              : p.basename(path),
          message: path == null
              ? 'The file is streamed as the raw request body.'
              : exists
              ? '${Formatters.bytes(file!.lengthSync())} · $path'
              : 'This file no longer exists at $path',
          action: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton(
                onPressed: _pick,
                child: Text(path == null ? 'Choose file…' : 'Change file…'),
              ),
              if (path != null) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => widget.onChanged(null),
                  child: const Text('Remove'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
