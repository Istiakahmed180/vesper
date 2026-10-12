import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/security/redactor.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/id.dart';
import '../../../../shared/widgets/all_rows_checkbox.dart';
import '../../../workspace/presentation/response_controller.dart';
import '../../../workspace/presentation/workspace_controller.dart';
import '../../domain/models/variable_extraction.dart';
import '../../domain/services/response_extractor.dart';

/// "Set variables" tab: after a successful response, copy values from it
/// into variables (e.g. a login token into the environment).
class ExtractionsEditor extends ConsumerStatefulWidget {
  const ExtractionsEditor({super.key, required this.tabId});
  final String tabId;

  @override
  ConsumerState<ExtractionsEditor> createState() => _ExtractionsEditorState();
}

class _ExtractionsEditorState extends ConsumerState<ExtractionsEditor> {
  String _ghostId = newId();

  void _set(List<VariableExtraction> rules) => ref
      .read(workspaceProvider.notifier)
      .updateDraft(
        widget.tabId,
        (d) => d.copyWith(options: d.options.copyWith(extractions: rules)),
      );

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final rules =
        ref.watch(
          requestTabProvider(
            widget.tabId,
          ).select((t) => t?.draft.options.extractions),
        ) ??
        const <VariableExtraction>[];
    final response = switch (ref.watch(responseProvider(widget.tabId))) {
      ResponseSuccess(:final response) => response,
      _ => null,
    };
    final preview = response == null
        ? const <String, ExtractedValue>{}
        : {
            for (final r in const ResponseExtractor().extract(response, rules))
              r.rule.id: r,
          };

    void update(VariableExtraction rule) {
      if (rules.any((r) => r.id == rule.id)) {
        _set([for (final r in rules) r.id == rule.id ? rule : r]);
      } else {
        setState(() => _ghostId = newId());
        _set([...rules, rule]);
      }
    }

    final label = Theme.of(context).textTheme.labelSmall;
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: Text(
            'After a successful response (2xx), these values are saved to '
            'variables, for example a login token. Use them as {{name}} in '
            'other requests.',
            style: TextStyle(fontSize: 12, color: colors.textMuted),
          ),
        ),
        Container(
          height: 28,
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: colors.border),
              bottom: BorderSide(color: colors.border),
            ),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 40,
                child: AllRowsCheckbox(
                  total: rules.length,
                  enabled: rules.where((r) => r.enabled).length,
                  onChanged: (on) =>
                      _set([for (final r in rules) r.copyWith(enabled: on)]),
                ),
              ),
              Expanded(flex: 3, child: Text('VARIABLE', style: label)),
              SizedBox(width: 120, child: Text('FROM', style: label)),
              Expanded(flex: 4, child: Text('PATH / HEADER', style: label)),
              SizedBox(width: 160, child: Text('SAVE TO', style: label)),
              Expanded(flex: 3, child: Text('LAST RESPONSE', style: label)),
              const SizedBox(width: 36),
            ],
          ),
        ),
        for (final rule in rules)
          _RuleRow(
            key: ValueKey(rule.id),
            rule: rule,
            preview: preview[rule.id],
            hasResponse: response != null,
            onChanged: update,
            onRemove: () => _set([
              for (final r in rules)
                if (r.id != rule.id) r,
            ]),
          ),
        _RuleRow(
          key: ValueKey(_ghostId),
          rule: VariableExtraction(id: _ghostId),
          ghost: true,
          hasResponse: false,
          onChanged: update,
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            'Paths: token · data.access_token · items[0].id · \$.user.name. '
            'Objects and lists are saved as JSON.',
            style: AppTheme.mono(context, size: 11.5, color: colors.textMuted),
          ),
        ),
      ],
    );
  }
}

class _RuleRow extends StatelessWidget {
  const _RuleRow({
    super.key,
    required this.rule,
    required this.onChanged,
    required this.hasResponse,
    this.onRemove,
    this.preview,
    this.ghost = false,
  });

  final VariableExtraction rule;
  final ValueChanged<VariableExtraction> onChanged;
  final VoidCallback? onRemove;
  final ExtractedValue? preview;
  final bool hasResponse;
  final bool ghost;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final mono = AppTheme.mono(context, size: 12.5);
    InputDecoration deco(String hint) => InputDecoration(
      hintText: hint,
      filled: false,
      isDense: true,
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
    );
    final value = preview?.value;
    final previewText = ghost || !rule.isActive
        ? ''
        : !hasResponse
        ? 'Send the request to try'
        : value == null
        ? (preview?.error ?? 'Not found')
        : Redactor.isSensitiveKey(rule.variable) && value.length > 8
        ? '${value.substring(0, 4)}…${value.substring(value.length - 4)}'
        : value;

    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: colors.border.withValues(alpha: 0.6)),
        ),
      ),
      child: Opacity(
        opacity: !rule.enabled && !ghost ? 0.5 : 1,
        child: Row(
          children: [
            SizedBox(
              width: 40,
              child: ghost
                  ? null
                  : Checkbox(
                      value: rule.enabled,
                      onChanged: (v) =>
                          onChanged(rule.copyWith(enabled: v ?? true)),
                    ),
            ),
            Expanded(
              flex: 3,
              child: _Cell(
                key: const ValueKey('rule-variable'),
                value: rule.variable,
                style: mono.copyWith(color: colors.variable),
                decoration: deco('token'),
                onChanged: (v) => onChanged(rule.copyWith(variable: v.trim())),
              ),
            ),
            SizedBox(
              width: 120,
              child: _Dropdown<ExtractionSource>(
                value: rule.source,
                values: ExtractionSource.values,
                label: (s) => s.label,
                onChanged: (s) => onChanged(rule.copyWith(source: s)),
              ),
            ),
            Expanded(
              flex: 4,
              child: _Cell(
                key: const ValueKey('rule-path'),
                value: rule.path,
                style: mono,
                decoration: deco(
                  rule.source == ExtractionSource.header
                      ? 'X-Auth-Token'
                      : 'token or data.access_token',
                ),
                onChanged: (v) => onChanged(rule.copyWith(path: v)),
              ),
            ),
            SizedBox(
              width: 160,
              child: _Dropdown<ExtractionTarget>(
                value: rule.target,
                values: ExtractionTarget.values,
                label: (t) => t.label,
                onChanged: (t) => onChanged(rule.copyWith(target: t)),
              ),
            ),
            Expanded(
              flex: 3,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  previewText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mono.copyWith(
                    fontSize: 12,
                    color: value != null ? colors.success : colors.textMuted,
                  ),
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

class _Dropdown<T> extends StatelessWidget {
  const _Dropdown({
    required this.value,
    required this.values,
    required this.label,
    required this.onChanged,
  });

  final T value;
  final List<T> values;
  final String Function(T) label;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => DropdownButtonHideUnderline(
    child: DropdownButton<T>(
      value: value,
      isDense: true,
      isExpanded: true,
      style: TextStyle(fontSize: 12.5, color: context.colors.textPrimary),
      items: [
        for (final v in values)
          DropdownMenuItem(
            value: v,
            child: Text(label(v), overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    ),
  );
}

class _Cell extends StatefulWidget {
  const _Cell({
    super.key,
    required this.value,
    required this.onChanged,
    required this.style,
    required this.decoration,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final TextStyle style;
  final InputDecoration decoration;

  @override
  State<_Cell> createState() => _CellState();
}

class _CellState extends State<_Cell> {
  late final _controller = TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(_Cell old) {
    super.didUpdateWidget(old);
    if (widget.value != _controller.text) _controller.text = widget.value;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _controller,
    style: widget.style,
    decoration: widget.decoration,
    onChanged: widget.onChanged,
  );
}
