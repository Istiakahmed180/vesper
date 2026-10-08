import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../settings/presentation/settings_controller.dart';
import '../../../workspace/presentation/workspace_controller.dart';
import '../../domain/models/api_request.dart';

/// Per-request overrides of global network settings, plus a description.
class RequestOptionsView extends ConsumerWidget {
  const RequestOptionsView({super.key, required this.tabId});
  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final options =
        ref.watch(requestTabProvider(tabId).select((t) => t?.draft.options)) ??
        const RequestOptions();
    final description =
        ref.watch(
          requestTabProvider(tabId).select((t) => t?.draft.description),
        ) ??
        '';
    final global = ref.watch(settingsProvider.select((s) => s.network));
    final colors = context.colors;
    void set(RequestOptions o) => ref
        .read(workspaceProvider.notifier)
        .updateDraft(tabId, (d) => d.copyWith(options: o));

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Request settings', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Override the global network settings for this request only.',
          style: TextStyle(fontSize: 12, color: colors.textMuted),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const SizedBox(
              width: 180,
              child: Text('Timeout (ms)', style: TextStyle(fontSize: 13)),
            ),
            SizedBox(
              width: 160,
              child: _NumberField(
                value: options.timeoutMs,
                hint: 'Global (${global.timeoutMs})',
                onChanged: (v) => set(
                  RequestOptions(
                    timeoutMs: v,
                    followRedirects: options.followRedirects,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            const SizedBox(
              width: 180,
              child: Text('Follow redirects', style: TextStyle(fontSize: 13)),
            ),
            DropdownButton<bool?>(
              value: options.followRedirects,
              isDense: true,
              items: [
                DropdownMenuItem(
                  value: null,
                  child: Text(
                    'Global (${global.followRedirects ? 'on' : 'off'})',
                  ),
                ),
                const DropdownMenuItem(value: true, child: Text('Always')),
                const DropdownMenuItem(value: false, child: Text('Never')),
              ],
              onChanged: (v) => set(
                RequestOptions(
                  timeoutMs: options.timeoutMs,
                  followRedirects: v,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
        Text('Description', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        _DescriptionField(
          value: description,
          onChanged: (v) => ref
              .read(workspaceProvider.notifier)
              .updateDraft(tabId, (d) => d.copyWith(description: v)),
        ),
      ],
    );
  }
}

class _NumberField extends StatefulWidget {
  const _NumberField({
    required this.value,
    required this.hint,
    required this.onChanged,
  });
  final int? value;
  final String hint;
  final ValueChanged<int?> onChanged;

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final _c = TextEditingController(text: widget.value?.toString() ?? '');

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _c,
    decoration: InputDecoration(hintText: widget.hint),
    keyboardType: TextInputType.number,
    onChanged: (v) {
      final n = int.tryParse(v.trim());
      widget.onChanged(n == null || n <= 0 ? null : n.clamp(100, 600000));
    },
  );
}

class _DescriptionField extends StatefulWidget {
  const _DescriptionField({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  State<_DescriptionField> createState() => _DescriptionFieldState();
}

class _DescriptionFieldState extends State<_DescriptionField> {
  late final _c = TextEditingController(text: widget.value);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _c,
    minLines: 4,
    maxLines: 12,
    decoration: const InputDecoration(hintText: 'What does this request do?'),
    onChanged: widget.onChanged,
  );
}
