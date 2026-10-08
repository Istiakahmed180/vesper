import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/id.dart';
import '../../../core/utils/platform_keys.dart';
import '../../../shared/widgets/dialogs.dart';
import '../../../shared/widgets/section_tabs.dart';
import '../../settings/presentation/settings_controller.dart';
import '../domain/environment_models.dart';
import 'environment_providers.dart';

/// Editor for one environment's variables. Edits are local until saved.
class EnvironmentEditor extends ConsumerStatefulWidget {
  const EnvironmentEditor({super.key, required this.environmentId});
  final String environmentId;

  @override
  ConsumerState<EnvironmentEditor> createState() => _EnvironmentEditorState();
}

class _EnvironmentEditorState extends ConsumerState<EnvironmentEditor> {
  Environment? _original;
  List<EnvVariable> _vars = [];
  String _ghostId = newId();
  final Set<String> _revealed = {};
  bool _saving = false;

  bool get _dirty {
    final o = _original;
    return o != null && !o.sameContentAs(o.copyWith(variables: _vars));
  }

  void _load(Environment env) {
    _original = env;
    _vars = [...env.variables];
  }

  Future<void> _save() async {
    final o = _original;
    if (o == null) return;
    setState(() => _saving = true);
    await guarded(
      context,
      () => ref
          .read(environmentRepositoryProvider)
          .saveEnvironment(o.copyWith(variables: _vars)),
      success: 'Environment saved',
    );
    if (mounted) setState(() => _saving = false);
  }

  void _update(EnvVariable v) {
    setState(() {
      final i = _vars.indexWhere((e) => e.id == v.id);
      if (i == -1) {
        _vars.add(v);
        _ghostId = newId();
      } else {
        _vars[i] = v;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final envs = ref.watch(environmentsProvider).value;
    final env = envs?.where((e) => e.id == widget.environmentId).firstOrNull;
    if (envs != null && env == null) {
      return const EmptyState(
        icon: Icons.delete_outline,
        title: 'This environment was deleted',
      );
    }
    if (env == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    // Pick up external changes (e.g. after save) only when not editing.
    if (_original == null || (!_dirty && !identical(_original, env))) {
      _load(env);
    }

    final activeId = ref.watch(
      settingsProvider.select((s) => s.activeEnvironmentId),
    );
    final isActive = activeId == env.id;

    return CallbackShortcuts(
      bindings: {
        SingleActivator(
          LogicalKeyboardKey.keyS,
          meta: PlatformKeys.isMac,
          control: !PlatformKeys.isMac,
        ): _save,
      },
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
                    env.isGlobal ? Icons.public : Icons.layers_outlined,
                    size: 20,
                    color: colors.accent,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          env.name,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          env.isGlobal
                              ? 'Global variables are available in every request. Active environments override them.'
                              : 'Use variables as {{name}} in URLs, headers, bodies and authorization.',
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!env.isGlobal)
                    OutlinedButton(
                      onPressed: () => ref
                          .read(settingsProvider.notifier)
                          .setActiveEnvironment(isActive ? null : env.id),
                      child: Text(isActive ? 'Deactivate' : 'Set active'),
                    ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _dirty && !_saving ? _save : null,
                    child: Text(_dirty ? 'Save' : 'Saved'),
                  ),
                ],
              ),
            ),
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
                  for (final v in _vars)
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
                      onRemove: () => setState(
                        () => _vars.removeWhere((e) => e.id == v.id),
                      ),
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
                      'Secret values are stored in the system keychain, masked in the UI, '
                      'never written to history and excluded from exports by default.',
                      style: TextStyle(fontSize: 11.5, color: colors.textMuted),
                    ),
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
