import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/app_providers.dart';
import '../../../../core/security/redactor.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../shared/widgets/dialogs.dart';
import '../../../../shared/widgets/section_tabs.dart';
import '../../../../shared/widgets/variable_scope.dart';
import '../../../settings/presentation/settings_controller.dart';
import '../../../workspace/presentation/workspace_controller.dart';
import '../../data/cookie_store.dart';
import '../../domain/services/url_utils.dart';

/// Cookies currently stored in the session cookie jar, highlighting the ones
/// that will be sent with this request.
class CookiesView extends ConsumerStatefulWidget {
  const CookiesView({super.key, required this.tabId});
  final String tabId;

  @override
  ConsumerState<CookiesView> createState() => _CookiesViewState();
}

class _CookiesViewState extends ConsumerState<CookiesView> {
  final Set<StoredCookie> _revealed = {};

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(cookieStoreProvider);
    final enabled = ref.watch(
      settingsProvider.select((s) => s.network.sendCookies),
    );
    final url =
        ref.watch(
          requestTabProvider(widget.tabId).select((t) => t?.draft.url),
        ) ??
        '';
    final resolver = VariableScope.watch(ref, context);
    final resolved = resolver(UrlParts.split(url).base);
    final uri = Uri.tryParse(
      UrlUtils.hasScheme(resolved) ? resolved : 'http://$resolved',
    );
    final colors = context.colors;

    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final all = store.all;
        final sent = uri == null || uri.host.isEmpty
            ? <StoredCookie>{}
            : store.forUri(uri).toSet();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 12, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      enabled
                          ? 'Cookies received in this session are sent automatically to matching hosts.'
                          : 'Automatic cookies are disabled in Settings → Network.',
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                  if (all.isNotEmpty)
                    TextButton.icon(
                      onPressed: () async {
                        if (await confirmDialog(
                          context,
                          title: 'Clear cookies',
                          message:
                              'Remove all ${all.length} cookies from this session?',
                          confirmLabel: 'Clear',
                        )) {
                          store.clear();
                        }
                      },
                      icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                      label: const Text('Clear all'),
                    ),
                ],
              ),
            ),
            Expanded(
              child: all.isEmpty
                  ? const EmptyState(
                      icon: Icons.cookie_outlined,
                      title: 'No cookies yet',
                      message:
                          'Cookies set by servers (Set-Cookie) will appear here.',
                    )
                  : ListView(
                      children: [
                        for (final c in all)
                          ListTile(
                            dense: true,
                            leading: Icon(
                              sent.contains(c)
                                  ? Icons.check_circle
                                  : Icons.circle_outlined,
                              size: 16,
                              color: sent.contains(c)
                                  ? colors.success
                                  : colors.textMuted,
                            ),
                            title: Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: c.name,
                                    style: TextStyle(
                                      color: colors.syntaxKey,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const TextSpan(text: ' = '),
                                  TextSpan(
                                    text: _revealed.contains(c)
                                        ? c.value
                                        : Redactor.maskValue(c.value),
                                    style: AppTheme.mono(context, size: 12),
                                  ),
                                ],
                              ),
                            ),
                            subtitle: Text(
                              '${c.domain}${c.path} · ${c.expires == null ? 'Session' : 'Expires ${Formatters.dateTime(c.expires!)}'}'
                              '${c.secure ? ' · Secure' : ''}${c.httpOnly ? ' · HttpOnly' : ''}',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: colors.textMuted,
                              ),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: _revealed.contains(c)
                                      ? 'Hide value'
                                      : 'Reveal value',
                                  onPressed: () => setState(
                                    () => _revealed.contains(c)
                                        ? _revealed.remove(c)
                                        : _revealed.add(c),
                                  ),
                                  icon: Icon(
                                    _revealed.contains(c)
                                        ? Icons.visibility_off_outlined
                                        : Icons.visibility_outlined,
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Delete cookie',
                                  onPressed: () => store.remove(c),
                                  icon: const Icon(Icons.close),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }
}
