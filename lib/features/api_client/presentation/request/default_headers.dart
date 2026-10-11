import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/variable_scope.dart';
import '../../../workspace/presentation/workspace_controller.dart';
import '../../domain/models/request_body.dart';
import '../../domain/services/url_utils.dart';

/// A header Vesper adds to every request unless switched off or overridden.
class DefaultHeader {
  const DefaultHeader(this.name, this.value, {this.optional = true});

  final String name;
  final String value;

  /// Whether the user can switch it off (the rest are set by the network
  /// layer when the request is sent).
  final bool optional;
}

/// The headers sent automatically with the request in [tabId].
List<DefaultHeader> defaultHeadersFor({
  required String resolvedUrl,
  required RequestBody body,
  required bool hasBody,
}) {
  final uri = Uri.tryParse(
    UrlUtils.hasScheme(resolvedUrl) ? resolvedUrl : 'http://$resolvedUrl',
  );
  final host = uri == null || uri.host.isEmpty
      ? '<calculated when sent>'
      : uri.hasPort
      ? '${uri.host}:${uri.port}'
      : uri.host;
  final contentType = body.impliedContentType;
  return [
    DefaultHeader('Host', host, optional: false),
    const DefaultHeader('User-Agent', AppConstants.userAgent),
    const DefaultHeader('Accept', '*/*'),
    const DefaultHeader('Accept-Encoding', 'gzip', optional: false),
    const DefaultHeader('Connection', 'keep-alive', optional: false),
    if (contentType != null && hasBody)
      DefaultHeader(
        'Content-Type',
        body.type == BodyType.formData
            ? 'multipart/form-data; boundary=<calculated when sent>'
            : contentType,
      ),
    if (hasBody)
      const DefaultHeader(
        'Content-Length',
        '<calculated when sent>',
        optional: false,
      ),
  ];
}

/// Collapsible list of the default headers above the user's headers.
class DefaultHeaders extends ConsumerStatefulWidget {
  const DefaultHeaders({super.key, required this.tabId});
  final String tabId;

  @override
  ConsumerState<DefaultHeaders> createState() => _DefaultHeadersState();
}

class _DefaultHeadersState extends ConsumerState<DefaultHeaders> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tab = ref.watch(requestTabProvider(widget.tabId));
    if (tab == null) return const SizedBox.shrink();
    final draft = tab.draft;
    final resolver = VariableScope.watch(ref, context);
    final defaults = defaultHeadersFor(
      resolvedUrl: resolver(UrlParts.split(draft.url).base),
      body: draft.body,
      hasBody: draft.method.allowsBody || draft.body.type != BodyType.none,
    );
    final userHeaders = {
      for (final h in draft.headers)
        if (h.isActive) h.key.trim().toLowerCase(),
    };
    final disabled = draft.options.disabledDefaultHeaders;
    final active = defaults
        .where(
          (d) =>
              !disabled.contains(d.name.toLowerCase()) &&
              !userHeaders.contains(d.name.toLowerCase()),
        )
        .length;
    final mono = AppTheme.mono(context, size: 12.5);

    void toggle(DefaultHeader header, bool on) {
      final name = header.name.toLowerCase();
      ref
          .read(workspaceProvider.notifier)
          .updateDraft(
            widget.tabId,
            (d) => d.copyWith(
              options: d.options.copyWith(
                disabledDefaultHeaders: on
                    ? ({...d.options.disabledDefaultHeaders}..remove(name))
                    : {...d.options.disabledDefaultHeaders, name},
              ),
            ),
          );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          key: const ValueKey('default-headers-toggle'),
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 12, 6),
            child: Row(
              children: [
                Icon(
                  _expanded ? Icons.expand_more : Icons.chevron_right,
                  size: 16,
                  color: colors.textMuted,
                ),
                const SizedBox(width: 4),
                Text(
                  'Default headers',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                const SizedBox(width: 6),
                Text(
                  '$active sent',
                  style: TextStyle(fontSize: 11, color: colors.textMuted),
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          for (final header in defaults)
            Builder(
              builder: (context) {
                final name = header.name.toLowerCase();
                final overridden = userHeaders.contains(name);
                final on = !disabled.contains(name);
                return Container(
                  key: ValueKey('default-header-$name'),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: colors.border.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                  child: Opacity(
                    opacity: on && !overridden ? 1 : 0.45,
                    child: Row(
                      children: [
                        SizedBox(
                          width: 40,
                          child: Tooltip(
                            message: header.optional
                                ? (on ? 'Don\'t send' : 'Send')
                                : 'Always sent',
                            child: Checkbox(
                              value: on,
                              onChanged: header.optional && !overridden
                                  ? (v) => toggle(header, v ?? true)
                                  : null,
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Text(
                              header.name,
                              style: mono.copyWith(
                                decoration: overridden
                                    ? TextDecoration.lineThrough
                                    : null,
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 3,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            ),
                            child: Text(
                              overridden ? 'Overridden below' : header.value,
                              overflow: TextOverflow.ellipsis,
                              style: mono.copyWith(color: colors.textSecondary),
                            ),
                          ),
                        ),
                        const SizedBox(width: 64),
                      ],
                    ),
                  ),
                );
              },
            ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: Text(
            'Your headers',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ),
      ],
    );
  }
}
