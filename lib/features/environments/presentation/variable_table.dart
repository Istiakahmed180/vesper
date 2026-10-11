import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/id.dart';
import '../domain/environment_models.dart';

/// Editable variable list (name, value, secret) with a trailing blank row
/// for adding. Used for environments and collection variables.
class VariableTable extends StatefulWidget {
  const VariableTable({
    super.key,
    required this.variables,
    required this.onChanged,
    this.footer =
        'Secret values are stored encrypted on this computer, masked in the UI, '
        'never written to history and excluded from exports by default.',
  });

  final List<EnvVariable> variables;
  final ValueChanged<List<EnvVariable>> onChanged;
  final String footer;

  @override
  State<VariableTable> createState() => _VariableTableState();
}

class _VariableTableState extends State<VariableTable> {
  String _ghostId = newId();
  final Set<String> _revealed = {};

  void _update(EnvVariable v) {
    final vars = [...widget.variables];
    final i = vars.indexWhere((e) => e.id == v.id);
    if (i == -1) {
      vars.add(v);
      setState(() => _ghostId = newId());
    } else {
      vars[i] = v;
    }
    widget.onChanged(vars);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 30,
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: colors.border),
              bottom: BorderSide(color: colors.border),
            ),
          ),
          child: Row(
            children: [
              const SizedBox(width: 44),
              Expanded(
                flex: 2,
                child: Text(
                  'VARIABLE',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              Expanded(
                flex: 4,
                child: Text(
                  'VALUE',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              SizedBox(
                width: 70,
                child: Text(
                  'SECRET',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              const SizedBox(width: 72),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              for (final v in widget.variables)
                _VarRow(
                  key: ValueKey(v.id),
                  variable: v,
                  revealed: _revealed.contains(v.id),
                  onReveal: () => setState(
                    () => _revealed.contains(v.id)
                        ? _revealed.remove(v.id)
                        : _revealed.add(v.id),
                  ),
                  onChanged: _update,
                  onRemove: () => widget.onChanged([
                    for (final e in widget.variables)
                      if (e.id != v.id) e,
                  ]),
                ),
              _VarRow(
                key: ValueKey(_ghostId),
                variable: EnvVariable(id: _ghostId),
                ghost: true,
                onChanged: _update,
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  widget.footer,
                  style: TextStyle(fontSize: 11.5, color: colors.textMuted),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _VarRow extends StatelessWidget {
  const _VarRow({
    super.key,
    required this.variable,
    required this.onChanged,
    this.onRemove,
    this.onReveal,
    this.revealed = false,
    this.ghost = false,
  });

  final EnvVariable variable;
  final ValueChanged<EnvVariable> onChanged;
  final VoidCallback? onRemove;
  final VoidCallback? onReveal;
  final bool revealed;
  final bool ghost;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final v = variable;
    final mono = AppTheme.mono(context, size: 12.5);
    InputDecoration deco(String hint) => InputDecoration(
      hintText: hint,
      filled: false,
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
    );
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: colors.border.withValues(alpha: 0.6)),
        ),
      ),
      child: Opacity(
        opacity: !v.enabled && !ghost ? 0.5 : 1,
        child: Row(
          children: [
            SizedBox(
              width: 44,
              child: ghost
                  ? null
                  : Checkbox(
                      value: v.enabled,
                      onChanged: (e) =>
                          onChanged(v.copyWith(enabled: e ?? true)),
                    ),
            ),
            Expanded(
              flex: 2,
              child: _Cell(
                value: v.key,
                style: mono.copyWith(color: colors.variable),
                decoration: deco('variable_name'),
                onChanged: (t) => onChanged(v.copyWith(key: t.trim())),
              ),
            ),
            Expanded(
              flex: 4,
              child: _Cell(
                value: v.value,
                style: mono,
                obscure: v.isSecret && !revealed,
                decoration: deco('value'),
                onChanged: (t) => onChanged(v.copyWith(value: t)),
              ),
            ),
            SizedBox(
              width: 70,
              child: ghost
                  ? null
                  : Switch(
                      value: v.isSecret,
                      onChanged: (s) => onChanged(v.copyWith(isSecret: s)),
                    ),
            ),
            SizedBox(
              width: 72,
              child: ghost
                  ? null
                  : Row(
                      children: [
                        if (v.isSecret)
                          IconButton(
                            tooltip: revealed ? 'Hide value' : 'Reveal value',
                            iconSize: 15,
                            onPressed: onReveal,
                            icon: Icon(
                              revealed
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                            ),
                          )
                        else
                          const SizedBox(width: 32),
                        IconButton(
                          tooltip: 'Remove',
                          iconSize: 15,
                          onPressed: onRemove,
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Cell extends StatefulWidget {
  const _Cell({
    required this.value,
    required this.onChanged,
    required this.style,
    required this.decoration,
    this.obscure = false,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final TextStyle style;
  final InputDecoration decoration;
  final bool obscure;

  @override
  State<_Cell> createState() => _CellState();
}

class _CellState extends State<_Cell> {
  late final _c = TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(_Cell old) {
    super.didUpdateWidget(old);
    if (widget.value != _c.text) _c.text = widget.value;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _c,
    style: widget.style,
    obscureText: widget.obscure,
    decoration: widget.decoration,
    onChanged: widget.onChanged,
  );
}
