import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/platform_keys.dart';
import '../../../shared/widgets/dialogs.dart';
import '../../../shared/widgets/section_tabs.dart';
import '../../workspaces/presentation/workspace_providers.dart';
import '../domain/environment_models.dart';
import 'environment_providers.dart';
import 'variable_table.dart';

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

    final activeId = ref.watch(activeEnvironmentIdProvider);
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
                          .read(activeWorkspaceIdProvider.notifier)
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
            Expanded(
              child: VariableTable(
                variables: _vars,
                onChanged: (vars) => setState(() => _vars = vars),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
