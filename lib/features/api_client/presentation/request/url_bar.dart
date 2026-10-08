import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/platform_keys.dart';
import '../../../../shared/widgets/method_badge.dart';
import '../../../../shared/widgets/variable_field.dart';
import '../../../workspace/presentation/response_controller.dart';
import '../../../workspace/presentation/workspace_actions.dart';
import '../../../workspace/presentation/workspace_controller.dart';
import '../../domain/models/http_method.dart';

/// Incremented to ask the visible URL field to take focus (Cmd/Ctrl+L).
final focusUrlRequestProvider = NotifierProvider<FocusUrlRequest, int>(
  FocusUrlRequest.new,
);

class FocusUrlRequest extends Notifier<int> {
  @override
  int build() => 0;
  void request() => state++;
}

class UrlBar extends ConsumerStatefulWidget {
  const UrlBar({super.key, required this.tabId});
  final String tabId;

  @override
  ConsumerState<UrlBar> createState() => _UrlBarState();
}

class _UrlBarState extends ConsumerState<UrlBar> {
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _onUrlChanged(String value) {
    // Pasting a full cURL command replaces the request.
    if (value.trimLeft().startsWith('curl ') && value.contains('://')) {
      if (WorkspaceActions(
        ref,
        context,
      ).importCurlText(value, replaceTabId: widget.tabId)) {
        return;
      }
    }
    ref.read(workspaceProvider.notifier).setUrl(widget.tabId, value);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final method =
        ref.watch(
          requestTabProvider(widget.tabId).select((t) => t?.draft.method),
        ) ??
        HttpMethod.get;
    final url =
        ref.watch(
          requestTabProvider(widget.tabId).select((t) => t?.draft.url),
        ) ??
        '';
    final loading = ref.watch(
      responseProvider(widget.tabId).select((s) => s is ResponseLoading),
    );
    final actions = WorkspaceActions(ref, context);
    ref.listen(focusUrlRequestProvider, (_, _) {
      _focus.requestFocus();
      final field = _focus.context
          ?.findAncestorStateOfType<EditableTextState>();
      field?.selectAll(SelectionChangedCause.keyboard);
    });

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 36,
              decoration: BoxDecoration(
                color: colors.canvas,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: colors.borderStrong),
              ),
              child: Row(
                children: [
                  _MethodPicker(
                    method: method,
                    onChanged: (m) => ref
                        .read(workspaceProvider.notifier)
                        .updateDraft(
                          widget.tabId,
                          (d) => d.copyWith(method: m),
                        ),
                  ),
                  Container(width: 1, height: 20, color: colors.border),
                  Expanded(
                    child: VariableField(
                      value: url,
                      focusNode: _focus,
                      monospace: true,
                      borderless: true,
                      // Credentials belong in Authorization/Headers.
                      suggestCredentials: false,
                      hint:
                          'Enter a URL, {{base_url}}/path, or paste a cURL command',
                      onChanged: _onUrlChanged,
                      onSubmitted: (_) => actions.send(widget.tabId),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: 36,
            child: loading
                ? OutlinedButton.icon(
                    onPressed: () => actions.cancel(widget.tabId),
                    icon: const Icon(Icons.stop_circle_outlined, size: 16),
                    label: const Text('Cancel'),
                  )
                : Tooltip(
                    message: 'Send (${PlatformKeys.mod} ${PlatformKeys.enter})',
                    child: FilledButton.icon(
                      onPressed: () => actions.send(widget.tabId),
                      icon: const Icon(Icons.send_rounded, size: 15),
                      label: const Text('Send'),
                    ),
                  ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            height: 36,
            child: Tooltip(
              message: 'Save (${PlatformKeys.combo('S')})',
              child: OutlinedButton.icon(
                onPressed: () => actions.save(widget.tabId),
                icon: const Icon(Icons.save_outlined, size: 16),
                label: const Text('Save'),
              ),
            ),
          ),
          MenuAnchor(
            builder: (context, controller, _) => IconButton(
              tooltip: 'More',
              onPressed: () =>
                  controller.isOpen ? controller.close() : controller.open(),
              icon: const Icon(Icons.more_horiz),
            ),
            menuChildren: [
              MenuItemButton(
                leadingIcon: const Icon(Icons.save_as_outlined, size: 16),
                onPressed: () => actions.save(widget.tabId, true),
                child: const Text('Save as…'),
              ),
              MenuItemButton(
                leadingIcon: const Icon(Icons.terminal, size: 16),
                onPressed: () => actions.copyAsCurl(widget.tabId),
                child: const Text('Copy as cURL'),
              ),
              MenuItemButton(
                leadingIcon: const Icon(Icons.copy_all_outlined, size: 16),
                onPressed: () => actions.duplicateTab(widget.tabId),
                child: const Text('Duplicate tab'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MethodPicker extends StatelessWidget {
  const _MethodPicker({required this.method, required this.onChanged});
  final HttpMethod method;
  final ValueChanged<HttpMethod> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MenuAnchor(
      builder: (context, controller, _) => InkWell(
        onTap: () => controller.isOpen ? controller.close() : controller.open(),
        borderRadius: const BorderRadius.horizontal(left: Radius.circular(6)),
        child: Container(
          width: 104,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  method.value,
                  style: TextStyle(
                    color: method.color(colors),
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                  ),
                ),
              ),
              Icon(Icons.expand_more, size: 16, color: colors.textMuted),
            ],
          ),
        ),
      ),
      menuChildren: [
        for (final m in HttpMethod.values)
          MenuItemButton(
            onPressed: () => onChanged(m),
            child: Text(
              m.value,
              style: TextStyle(
                color: m.color(colors),
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
              ),
            ),
          ),
      ],
    );
  }
}
