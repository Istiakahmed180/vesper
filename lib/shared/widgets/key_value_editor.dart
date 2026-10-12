import 'package:flutter/material.dart';

import '../../core/security/redactor.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/id.dart';
import '../../features/api_client/domain/models/key_value.dart';
import 'all_rows_checkbox.dart';
import 'dialogs.dart';
import 'fake_data_picker.dart';
import 'variable_autocomplete.dart';
import 'variable_field.dart';

/// Editable key/value table with an always-present trailing "new row" and a
/// bulk text mode. Rows keep stable ids so focus survives rebuilds.
class KeyValueEditor extends StatefulWidget {
  const KeyValueEditor({
    super.key,
    required this.rows,
    required this.onChanged,
    this.keyHint = 'Key',
    this.valueHint = 'Value',
    this.maskSensitive = false,
    this.bulkSeparator = ':',
    this.keySuggestions,
    this.valueSuggestions,
    this.fakeData = false,
  });

  final List<KeyValue> rows;
  final ValueChanged<List<KeyValue>> onChanged;
  final String keyHint;
  final String valueHint;
  final bool maskSensitive;

  /// Separator used in bulk edit ("key: value" for headers, "key=value" else).
  final String bulkSeparator;

  /// Dropdown suggestions for the key column (e.g. header names).
  final List<VariableSuggestion> Function(String text)? keySuggestions;

  /// Dropdown suggestions for a value, given its row's key.
  final List<VariableSuggestion> Function(String key, String text)?
  valueSuggestions;

  /// Shows a dice button in each value cell for inserting fake data.
  final bool fakeData;

  @override
  State<KeyValueEditor> createState() => _KeyValueEditorState();
}

class _KeyValueEditorState extends State<KeyValueEditor> {
  String _ghostId = newId();
  bool _bulk = false;
  final Set<String> _revealed = {};

  void _update(KeyValue row) {
    final exists = widget.rows.any((r) => r.id == row.id);
    if (exists) {
      widget.onChanged([for (final r in widget.rows) r.id == row.id ? row : r]);
    } else {
      setState(() => _ghostId = newId());
      widget.onChanged([...widget.rows, row]);
    }
  }

  void _remove(String id) =>
      widget.onChanged(widget.rows.where((r) => r.id != id).toList());

  String _toBulk() => widget.rows
      .map(
        (r) =>
            '${r.enabled ? '' : '//'}${r.key}${widget.bulkSeparator}'
            '${widget.bulkSeparator == ':' ? ' ' : ''}${r.value}',
      )
      .join('\n');

  List<KeyValue> _fromBulk(String text) {
    final rows = <KeyValue>[];
    final previous = widget.rows;
    var i = 0;
    for (final raw in text.split('\n')) {
      if (raw.trim().isEmpty) continue;
      var line = raw;
      var enabled = true;
      if (line.trimLeft().startsWith('//')) {
        enabled = false;
        line = line.trimLeft().substring(2);
      }
      final sep = line.indexOf(widget.bulkSeparator);
      final key = (sep == -1 ? line : line.substring(0, sep)).trim();
      final value = sep == -1 ? '' : line.substring(sep + 1).trim();
      final prev = i < previous.length ? previous[i] : null;
      rows.add(
        prev != null
            ? prev.copyWith(key: key, value: value, enabled: enabled)
            : KeyValue(key: key, value: value, enabled: enabled),
      );
      i++;
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final activeCount = widget.rows.where((r) => r.isActive).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 6),
          child: Row(
            children: [
              Text(
                activeCount == 0 ? 'No active entries' : '$activeCount active',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              const Spacer(),
              if (widget.rows.isNotEmpty)
                TextButton.icon(
                  key: const ValueKey('clear-rows'),
                  onPressed: () async {
                    final ok = await confirmDialog(
                      context,
                      title: 'Clear all',
                      message:
                          'Remove all ${widget.rows.length} '
                          '${widget.keyHint.toLowerCase()} row(s)?',
                      confirmLabel: 'Clear',
                    );
                    if (ok) widget.onChanged(const []);
                  },
                  icon: const Icon(Icons.clear_all, size: 15),
                  label: const Text('Clear'),
                ),
              TextButton.icon(
                onPressed: () => setState(() => _bulk = !_bulk),
                icon: Icon(
                  _bulk ? Icons.table_rows_outlined : Icons.notes,
                  size: 15,
                ),
                label: Text(_bulk ? 'Table view' : 'Bulk edit'),
              ),
            ],
          ),
        ),
        if (_bulk)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: _BulkEditor(
              initial: _toBulk(),
              hint:
                  'key${widget.bulkSeparator}${widget.bulkSeparator == ':' ? ' ' : ''}value — one per line, prefix with // to disable',
              onChanged: (text) => widget.onChanged(_fromBulk(text)),
            ),
          )
        else ...[
          _HeaderRow(
            keyHint: widget.keyHint,
            valueHint: widget.valueHint,
            leading: AllRowsCheckbox(
              total: widget.rows.length,
              enabled: widget.rows.where((r) => r.enabled).length,
              onChanged: (on) => widget.onChanged([
                for (final r in widget.rows) r.copyWith(enabled: on),
              ]),
            ),
          ),
          for (final row in widget.rows)
            _KeyValueRow(
              key: ValueKey(row.id),
              row: row,
              keyHint: widget.keyHint,
              valueHint: widget.valueHint,
              obscure:
                  widget.maskSensitive &&
                  !_revealed.contains(row.id) &&
                  Redactor.isSensitiveHeader(row.key) &&
                  !row.value.trim().startsWith('{{'),
              onReveal:
                  widget.maskSensitive && Redactor.isSensitiveHeader(row.key)
                  ? () => setState(
                      () => _revealed.contains(row.id)
                          ? _revealed.remove(row.id)
                          : _revealed.add(row.id),
                    )
                  : null,
              revealed: _revealed.contains(row.id),
              keySuggestions: widget.keySuggestions,
              valueSuggestions: widget.valueSuggestions,
              fakeData: widget.fakeData,
              onChanged: _update,
              onRemove: () => _remove(row.id),
            ),
          _KeyValueRow(
            key: ValueKey(_ghostId),
            row: KeyValue(id: _ghostId),
            keyHint: widget.keyHint,
            valueHint: widget.valueHint,
            ghost: true,
            keySuggestions: widget.keySuggestions,
            valueSuggestions: widget.valueSuggestions,
            fakeData: widget.fakeData,
            onChanged: _update,
          ),
          Divider(color: colors.border, height: 1),
        ],
      ],
    );
  }
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({
    required this.keyHint,
    required this.valueHint,
    required this.leading,
  });
  final String keyHint;
  final String valueHint;
  final Widget leading;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall;
    return Container(
      height: 28,
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: context.colors.border),
          bottom: BorderSide(color: context.colors.border),
        ),
      ),
      child: Row(
        children: [
          SizedBox(width: 40, child: leading),
          Expanded(flex: 2, child: Text(keyHint.toUpperCase(), style: style)),
          Expanded(flex: 3, child: Text(valueHint.toUpperCase(), style: style)),
          const SizedBox(width: 64),
        ],
      ),
    );
  }
}

class _KeyValueRow extends StatefulWidget {
  const _KeyValueRow({
    super.key,
    required this.row,
    required this.onChanged,
    required this.keyHint,
    required this.valueHint,
    this.onRemove,
    this.ghost = false,
    this.obscure = false,
    this.onReveal,
    this.revealed = false,
    this.keySuggestions,
    this.valueSuggestions,
    this.fakeData = false,
  });

  final KeyValue row;
  final bool fakeData;
  final List<VariableSuggestion> Function(String text)? keySuggestions;
  final List<VariableSuggestion> Function(String key, String text)?
  valueSuggestions;
  final ValueChanged<KeyValue> onChanged;
  final VoidCallback? onRemove;
  final String keyHint;
  final String valueHint;
  final bool ghost;
  final bool obscure;
  final VoidCallback? onReveal;
  final bool revealed;

  @override
  State<_KeyValueRow> createState() => _KeyValueRowState();
}

class _KeyValueRowState extends State<_KeyValueRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final row = widget.row;
    final dim = !row.enabled && !widget.ghost;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        decoration: BoxDecoration(
          color: _hover ? colors.hover : null,
          border: Border(
            bottom: BorderSide(color: colors.border.withValues(alpha: 0.6)),
          ),
        ),
        child: Opacity(
          opacity: dim ? 0.5 : 1,
          child: Row(
            children: [
              SizedBox(
                width: 40,
                child: widget.ghost
                    ? null
                    : Checkbox(
                        value: row.enabled,
                        onChanged: (v) =>
                            widget.onChanged(row.copyWith(enabled: v ?? true)),
                      ),
              ),
              Expanded(
                flex: 2,
                child: VariableField(
                  value: row.key,
                  hint: widget.keyHint,
                  borderless: true,
                  monospace: true,
                  suggestions: widget.keySuggestions,
                  onChanged: (v) => widget.onChanged(row.copyWith(key: v)),
                ),
              ),
              Container(
                width: 1,
                height: 30,
                color: colors.border.withValues(alpha: 0.6),
              ),
              Expanded(
                flex: 3,
                child: VariableField(
                  value: row.value,
                  hint: widget.valueHint,
                  borderless: true,
                  monospace: true,
                  obscure: widget.obscure,
                  suggestions: widget.valueSuggestions == null
                      ? null
                      : (text) => widget.valueSuggestions!(row.key, text),
                  onChanged: (v) => widget.onChanged(row.copyWith(value: v)),
                ),
              ),
              if (widget.fakeData)
                FakeDataButton(
                  onPicked: (token) => widget.onChanged(
                    row.copyWith(value: '${row.value}$token'),
                  ),
                ),
              SizedBox(
                width: 64,
                child: widget.ghost
                    ? null
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (widget.onReveal != null)
                            IconButton(
                              tooltip: widget.revealed
                                  ? 'Hide value'
                                  : 'Reveal value',
                              iconSize: 15,
                              onPressed: widget.onReveal,
                              icon: Icon(
                                widget.revealed
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                              ),
                            ),
                          AnimatedOpacity(
                            opacity: _hover ? 1 : 0,
                            duration: const Duration(milliseconds: 100),
                            child: IconButton(
                              tooltip: 'Remove',
                              iconSize: 15,
                              onPressed: widget.onRemove,
                              icon: const Icon(Icons.close),
                            ),
                          ),
                          const SizedBox(width: 4),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BulkEditor extends StatefulWidget {
  const _BulkEditor({
    required this.initial,
    required this.onChanged,
    required this.hint,
  });
  final String initial;
  final String hint;
  final ValueChanged<String> onChanged;

  @override
  State<_BulkEditor> createState() => _BulkEditorState();
}

class _BulkEditorState extends State<_BulkEditor> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _controller,
    maxLines: null,
    minLines: 8,
    style: AppTheme.mono(context),
    decoration: InputDecoration(hintText: widget.hint),
    onChanged: widget.onChanged,
  );
}
