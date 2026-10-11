import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/security/redactor.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/dialogs.dart';
import '../../../shared/widgets/method_badge.dart';
import '../../../shared/widgets/section_tabs.dart';
import '../../api_client/domain/models/request_auth.dart';
import '../../api_client/domain/services/url_utils.dart';
import '../../collections/presentation/collection_providers.dart';
import '../../workspace/presentation/response_controller.dart';
import '../../workspace/presentation/workspace_controller.dart';
import '../domain/history_models.dart';
import 'history_providers.dart';

Future<void> clearHistoryCommand(BuildContext context, WidgetRef ref) async {
  final ok = await confirmDialog(
    context,
    title: 'Clear history',
    message: 'Remove all request history? Saved requests are not affected.',
    confirmLabel: 'Clear history',
  );
  if (ok && context.mounted) {
    await guarded(
      context,
      () => ref.read(historyRepositoryProvider).clear(),
      success: 'History cleared',
    );
  }
}

/// Opens a history entry in a new tab, optionally sending it right away.
/// History never stores literal secrets, so entries whose credentials were
/// stripped open with a notice instead of being sent.
void openHistoryEntry(WidgetRef ref, HistoryEntry entry, {bool run = false}) {
  final request = entry.request;
  final missingSecrets =
      (request.auth is! NoAuth &&
          request.auth is! InheritAuth &&
          request.auth.secrets.isEmpty) ||
      request.headers.any(
        (h) =>
            h.enabled && h.value.isEmpty && Redactor.isSensitiveHeader(h.key),
      );
  final path = displayPath(request.url);
  // Snapshots don't record the collection; an inheriting request gets it
  // back from its saved request so it sends the collection's auth again.
  final savedId = entry.requestId;
  final collectionId = request.auth is InheritAuth && savedId != null
      ? ref
            .read(collectionTreesProvider)
            .value
            ?.where((t) => t.allRequests.any((r) => r.id == savedId))
            .firstOrNull
            ?.collection
            .id
      : null;
  final tabId = ref
      .read(workspaceProvider.notifier)
      .newRequestTab(
        request.copyWith(
          name: '${request.method.value} ${path.isEmpty ? request.url : path}',
          collectionId: () => collectionId,
        ),
        missingSecrets
            ? 'Credentials are not stored in history. Re-enter them (or use {{variables}}) before sending.'
            : null,
      );
  if (run && !missingSecrets) ref.read(responseProvider(tabId).notifier).send();
}

/// Path of a raw request URL for display, keeping `{{variables}}` readable
/// (`{{base_url}}/users?id=1` → `/users`).
String displayPath(String url) {
  final base = UrlParts.split(url).base;
  final withoutOrigin = base.replaceFirst(
    RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*://[^/]*|\{\{[^{}]+\}\})'),
    '',
  );
  return withoutOrigin;
}

class HistoryPanel extends ConsumerWidget {
  const HistoryPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(historyProvider);
    final query = ref.watch(sidebarSearchProvider).trim().toLowerCase();
    return history.when(
      loading: () => const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      error: (_, _) => const EmptyState(
        icon: Icons.error_outline,
        title: 'Could not load history',
      ),
      data: (entries) {
        final filtered = query.isEmpty
            ? entries
            : entries
                  .where(
                    (e) =>
                        e.url.toLowerCase().contains(query) ||
                        e.method.value.toLowerCase() == query,
                  )
                  .toList();
        if (entries.isEmpty) {
          return const EmptyState(
            icon: Icons.history,
            title: 'No history yet',
            message: 'Requests you send appear here.',
          );
        }
        if (filtered.isEmpty) {
          return const EmptyState(icon: Icons.search_off, title: 'No matches');
        }

        // Group by calendar day.
        final rows = <Object>[];
        String? lastDay;
        for (final e in filtered) {
          final day = _dayLabel(e.executedAt);
          if (day != lastDay) {
            rows.add(day);
            lastDay = day;
          }
          rows.add(e);
        }
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 24),
          itemCount: rows.length,
          itemBuilder: (context, i) {
            final row = rows[i];
            if (row is String) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 12, 4),
                child: Text(
                  row.toUpperCase(),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              );
            }
            return _HistoryRow(entry: row as HistoryEntry);
          },
        );
      },
    );
  }

  static String _dayLabel(DateTime t) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(t.year, t.month, t.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    return Formatters.dateTime(day).split(' ').first;
  }
}

class _HistoryRow extends ConsumerStatefulWidget {
  const _HistoryRow({required this.entry});
  final HistoryEntry entry;

  @override
  ConsumerState<_HistoryRow> createState() => _HistoryRowState();
}

class _HistoryRowState extends ConsumerState<_HistoryRow> {
  final _menu = MenuController();
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final e = widget.entry;
    return MenuAnchor(
      controller: _menu,
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(Icons.open_in_new, size: 16),
          onPressed: () => openHistoryEntry(ref, e),
          child: const Text('Open in new tab'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.replay, size: 16),
          onPressed: () => openHistoryEntry(ref, e, run: true),
          child: const Text('Re-run'),
        ),
        const Divider(),
        MenuItemButton(
          leadingIcon: Icon(
            Icons.delete_outline,
            size: 16,
            color: colors.danger,
          ),
          onPressed: () => ref.read(historyRepositoryProvider).delete(e.id),
          child: Text('Delete', style: TextStyle(color: colors.danger)),
        ),
      ],
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => openHistoryEntry(ref, e),
          onSecondaryTapUp: (d) => _menu.open(position: d.localPosition),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 6),
            padding: const EdgeInsets.fromLTRB(8, 5, 4, 5),
            decoration: BoxDecoration(
              color: _hover ? colors.hover : null,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Row(
              children: [
                MethodBadge(e.method, width: 42),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        e.url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Text(
                            e.failed ? 'Error' : '${e.statusCode}',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: colors.statusColor(e.statusCode),
                            ),
                          ),
                          if (!e.failed)
                            Text(
                              ' · ${Formatters.duration(e.duration)} · ${Formatters.bytes(e.sizeBytes)}',
                              style: TextStyle(
                                fontSize: 11,
                                color: colors.textMuted,
                              ),
                            ),
                          const Spacer(),
                          Text(
                            Formatters.relativeTime(e.executedAt),
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (_hover)
                  IconButton(
                    tooltip: 'Re-run',
                    iconSize: 15,
                    onPressed: () => openHistoryEntry(ref, e, run: true),
                    icon: const Icon(Icons.replay),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
