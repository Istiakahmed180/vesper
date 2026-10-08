import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/errors/app_failure.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/utils/platform_keys.dart';
import '../../../../shared/widgets/code/code_view.dart';
import '../../../../shared/widgets/dialogs.dart';
import '../../../../shared/widgets/section_tabs.dart';
import '../../../workspace/presentation/response_controller.dart';
import '../../domain/models/api_response.dart';
import 'body_formatter.dart';

class ResponsePanel extends ConsumerWidget {
  const ResponsePanel({super.key, required this.tabId});

  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(responseProvider(tabId));
    return ColoredBox(
      color: context.colors.panel,
      child: switch (state) {
        ResponseIdle() => EmptyState(
          icon: Icons.send_outlined,
          title: 'Send a request to see the response',
          message:
              'Press ${PlatformKeys.mod} ${PlatformKeys.enter} or click Send.',
        ),
        ResponseLoading(:final startedAt) => _Loading(
          startedAt: startedAt,
          onCancel: () => ref.read(responseProvider(tabId).notifier).cancel(),
        ),
        ResponseFailure(:final failure) => _FailureView(failure: failure),
        ResponseSuccess(:final response) => _ResponseView(
          key: ObjectKey(response),
          response: response,
        ),
      },
    );
  }
}

class _Loading extends StatefulWidget {
  const _Loading({required this.startedAt, required this.onCancel});
  final DateTime startedAt;
  final VoidCallback onCancel;

  @override
  State<_Loading> createState() => _LoadingState();
}

class _LoadingState extends State<_Loading> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => setState(() {}),
    );
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = DateTime.now().difference(widget.startedAt);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(height: 14),
          Text(
            'Sending request… ${Formatters.duration(elapsed)}',
            style: TextStyle(color: context.colors.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: widget.onCancel,
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}

class _FailureView extends StatelessWidget {
  const _FailureView({required this.failure});
  final AppFailure failure;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final cancelled =
        failure is NetworkFailure &&
        (failure as NetworkFailure).kind == NetworkFailureKind.cancelled;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              cancelled ? Icons.block : Icons.cloud_off_outlined,
              size: 34,
              color: cancelled ? colors.textMuted : colors.danger,
            ),
            const SizedBox(height: 12),
            Text(failure.title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: SelectableText(
                failure.message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResponseView extends StatefulWidget {
  const _ResponseView({super.key, required this.response});
  final ApiResponse response;

  @override
  State<_ResponseView> createState() => _ResponseViewState();
}

class _ResponseViewState extends State<_ResponseView> {
  int _section = 0;

  @override
  Widget build(BuildContext context) {
    final r = widget.response;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionTabs(
          tabs: [
            const SectionTab('Body'),
            SectionTab('Headers', badge: '${r.headers.length}'),
            SectionTab(
              'Cookies',
              badge: r.cookies.isEmpty ? null : '${r.cookies.length}',
            ),
            const SectionTab('Details'),
          ],
          selected: _section,
          onSelected: (i) => setState(() => _section = i),
          trailing: _StatusSummary(response: r),
        ),
        Expanded(
          child: IndexedStack(
            index: _section,
            children: [
              _BodyView(response: r),
              _HeadersTable(headers: r.headers),
              _CookiesTable(cookies: r.cookies),
              _DetailsView(response: r),
            ],
          ),
        ),
      ],
    );
  }
}

class _StatusSummary extends StatelessWidget {
  const _StatusSummary({required this.response});
  final ApiResponse response;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final statusColor = colors.statusColor(response.statusCode);
    Widget metric(String label, String value, {String? tooltip}) => Tooltip(
      message: tooltip ?? '',
      child: Padding(
        padding: const EdgeInsets.only(left: 14),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: '$label ',
                style: TextStyle(color: colors.textMuted, fontSize: 12),
              ),
              TextSpan(
                text: value,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: statusColor.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            '${response.statusCode} ${response.statusMessage}'.trim(),
            style: TextStyle(
              color: statusColor,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        metric('Time', Formatters.duration(response.duration)),
        metric(
          'Size',
          Formatters.bytes(response.bodySize + response.headersSize),
          tooltip:
              'Body ${Formatters.bytes(response.bodySize)} · Headers ${Formatters.bytes(response.headersSize)}',
        ),
        const SizedBox(width: 6),
      ],
    );
  }
}

class _BodyView extends StatefulWidget {
  const _BodyView({required this.response});
  final ApiResponse response;

  @override
  State<_BodyView> createState() => _BodyViewState();
}

class _BodyViewState extends State<_BodyView> {
  late BodyView _view = widget.response.contentKind == ResponseContentKind.image
      ? BodyView.preview
      : BodyView.pretty;
  final Map<BodyView, Future<FormattedBody>> _cache = {};
  CodeViewController? _controller;
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  bool _searchOpen = false;
  Timer? _searchDebounce;

  ApiResponse get r => widget.response;

  Future<FormattedBody> _formatted(BodyView view) => _cache[view] ??=
      formatResponseBody(r, view == BodyView.preview ? BodyView.pretty : view);

  @override
  void dispose() {
    _controller?.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    final text = r.isTextual
        ? (await _formatted(
            _view == BodyView.raw ? BodyView.raw : BodyView.pretty,
          )).text
        : null;
    if (text == null) {
      if (mounted) {
        showToast(
          context,
          'Binary responses cannot be copied as text.',
          error: true,
        );
      }
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) showToast(context, 'Response copied to clipboard');
  }

  Future<void> _save() async {
    try {
      final uri = await FilePicker.saveFile(
        dialogTitle: 'Save response',
        fileName: r.suggestedFileName,
        bytes: r.bodyBytes,
      );
      if (uri != null && mounted) {
        showToast(context, 'Saved ${p.basename(uri.toFilePath())}');
      }
    } catch (_) {
      if (mounted) showToast(context, 'Could not save the file.', error: true);
    }
  }

  Future<void> _openInBrowser() async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File(
        p.join(
          dir.path,
          'vesper-preview-${DateTime.now().millisecondsSinceEpoch}.html',
        ),
      );
      await file.writeAsBytes(r.bodyBytes);
      await launchUrl(Uri.file(file.path));
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not open the browser.', error: true);
      }
    }
  }

  void _toggleSearch() {
    setState(() => _searchOpen = !_searchOpen);
    if (_searchOpen) {
      _searchFocus.requestFocus();
    } else {
      _searchController.clear();
      _controller?.search('');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final kind = r.contentKind;
    final views = [
      BodyView.pretty,
      BodyView.raw,
      if (kind == ResponseContentKind.image || kind == ResponseContentKind.html)
        BodyView.preview,
    ];

    return CallbackShortcuts(
      bindings: {
        SingleActivator(
          LogicalKeyboardKey.keyF,
          meta: PlatformKeys.isMac,
          control: !PlatformKeys.isMac,
        ): _toggleSearch,
      },
      child: Focus(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 38,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  if (r.isTextual || kind == ResponseContentKind.image)
                    Segmented<BodyView>(
                      values: views,
                      selected: _view,
                      label: (v) => switch (v) {
                        BodyView.pretty => 'Pretty',
                        BodyView.raw => 'Raw',
                        BodyView.preview => 'Preview',
                      },
                      onChanged: (v) => setState(() => _view = v),
                    ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      r.contentType.isEmpty
                          ? 'No content type'
                          : r.contentType.split(';').first,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: colors.textMuted),
                    ),
                  ),
                  if (_searchOpen) _searchBox(colors),
                  if (_controller?.hasFolds ?? false) ...[
                    IconButton(
                      tooltip: 'Collapse all',
                      onPressed: () => _controller?.collapseAll(),
                      icon: const Icon(Icons.unfold_less),
                    ),
                    IconButton(
                      tooltip: 'Expand all',
                      onPressed: () => _controller?.expandAll(),
                      icon: const Icon(Icons.unfold_more),
                    ),
                  ],
                  if (r.isTextual)
                    IconButton(
                      tooltip: 'Search (${PlatformKeys.combo('F')})',
                      onPressed: _toggleSearch,
                      icon: const Icon(Icons.search),
                    ),
                  IconButton(
                    tooltip: 'Copy body',
                    onPressed: _copy,
                    icon: const Icon(Icons.copy_outlined),
                  ),
                  IconButton(
                    tooltip: 'Save response to file',
                    onPressed: _save,
                    icon: const Icon(Icons.download_outlined),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: colors.border),
            Expanded(child: _content(colors)),
          ],
        ),
      ),
    );
  }

  Widget _searchBox(VesperColors colors) {
    final c = _controller;
    final count = c == null || c.query.isEmpty
        ? ''
        : (c.matches.isEmpty
              ? 'No results'
              : '${c.currentMatch + 1}/${c.matches.length}');
    return Row(
      children: [
        SizedBox(
          width: 160,
          height: 28,
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): _toggleSearch,
              const SingleActivator(
                LogicalKeyboardKey.enter,
                shift: true,
              ): () =>
                  c?.nextMatch(-1),
            },
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocus,
              style: const TextStyle(fontSize: 12.5),
              decoration: const InputDecoration(
                hintText: 'Find in body',
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 6,
                ),
              ),
              onChanged: (v) {
                _searchDebounce?.cancel();
                _searchDebounce = Timer(const Duration(milliseconds: 200), () {
                  c?.search(v);
                  setState(() {});
                });
              },
              onSubmitted: (_) {
                c?.nextMatch();
                setState(() {});
                _searchFocus.requestFocus();
              },
            ),
          ),
        ),
        SizedBox(
          width: 70,
          child: Text(
            count,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11.5, color: colors.textMuted),
          ),
        ),
        IconButton(
          tooltip: 'Previous match',
          onPressed: () => setState(() => c?.nextMatch(-1)),
          icon: const Icon(Icons.keyboard_arrow_up),
        ),
        IconButton(
          tooltip: 'Next match',
          onPressed: () => setState(() => c?.nextMatch()),
          icon: const Icon(Icons.keyboard_arrow_down),
        ),
      ],
    );
  }

  Widget _content(VesperColors colors) {
    final kind = r.contentKind;
    if (r.bodyBytes.isEmpty) {
      return const EmptyState(
        icon: Icons.inbox_outlined,
        title: 'This response has no body',
      );
    }
    if (_view == BodyView.preview && kind == ResponseContentKind.image) {
      return Center(
        child: InteractiveViewer(
          child: Image.memory(
            r.bodyBytes,
            errorBuilder: (_, _, _) => const EmptyState(
              icon: Icons.broken_image_outlined,
              title: 'The image could not be decoded',
            ),
          ),
        ),
      );
    }
    if (_view == BodyView.preview && kind == ResponseContentKind.html) {
      return EmptyState(
        icon: Icons.open_in_browser,
        title: 'Preview HTML in your browser',
        message:
            'Vesper does not execute HTML or scripts inside the app. '
            'The page is written to a temporary file and opened in your default browser.',
        action: FilledButton(
          onPressed: _openInBrowser,
          child: const Text('Open in browser'),
        ),
      );
    }
    if (!r.isTextual) {
      return EmptyState(
        icon: Icons.insert_drive_file_outlined,
        title: 'Binary response (${Formatters.bytes(r.bodySize)})',
        message: 'Save the response to a file to inspect it.',
        action: OutlinedButton(
          onPressed: _save,
          child: const Text('Save to file'),
        ),
      );
    }

    return FutureBuilder<FormattedBody>(
      future: _formatted(_view),
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data == null) {
          if (snapshot.hasError) {
            return const EmptyState(
              icon: Icons.error_outline,
              title: 'Could not render the body',
            );
          }
          return const Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        var controller = _controller;
        if (controller == null) {
          controller = _controller = CodeViewController(data);
          // The toolbar (fold buttons, search) depends on the controller.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() {});
          });
        } else if (!identical(controller.body, data)) {
          controller.body = data;
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (data.notice != null)
              Container(
                color: colors.warning.withValues(alpha: 0.1),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Text(
                  data.notice!,
                  style: TextStyle(fontSize: 12, color: colors.warning),
                ),
              ),
            Expanded(child: CodeView(controller: controller)),
          ],
        );
      },
    );
  }
}

class _HeadersTable extends StatelessWidget {
  const _HeadersTable({required this.headers});
  final List<MapEntry<String, String>> headers;

  @override
  Widget build(BuildContext context) {
    if (headers.isEmpty) {
      return const EmptyState(icon: Icons.list_alt, title: 'No headers');
    }
    return _KeyValueList(rows: [for (final h in headers) (h.key, h.value)]);
  }
}

class _KeyValueList extends StatelessWidget {
  const _KeyValueList({required this.rows});
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final mono = AppTheme.mono(context, size: 12);
    return SelectionArea(
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: rows.length,
        separatorBuilder: (_, _) =>
            Divider(height: 1, color: colors.border.withValues(alpha: 0.6)),
        itemBuilder: (context, i) {
          final (k, v) = rows[i];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 240,
                  child: Text(
                    k,
                    style: mono.copyWith(
                      color: colors.syntaxKey,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                Expanded(child: Text(v, style: mono)),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _CookiesTable extends StatelessWidget {
  const _CookiesTable({required this.cookies});
  final List<ResponseCookie> cookies;

  @override
  Widget build(BuildContext context) {
    if (cookies.isEmpty) {
      return const EmptyState(
        icon: Icons.cookie_outlined,
        title: 'No cookies',
        message: 'The server did not set any cookies in this response.',
      );
    }
    final colors = context.colors;
    final style = TextStyle(fontSize: 12, color: colors.textSecondary);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: SelectionArea(
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          border: TableBorder(
            horizontalInside: BorderSide(color: colors.border),
          ),
          children: [
            TableRow(
              children: [
                for (final h in [
                  'Name',
                  'Value',
                  'Domain',
                  'Path',
                  'Expires',
                  'HttpOnly',
                  'Secure',
                ])
                  Padding(
                    padding: const EdgeInsets.fromLTRB(0, 4, 18, 6),
                    child: Text(
                      h.toUpperCase(),
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
              ],
            ),
            for (final c in cookies)
              TableRow(
                children: [
                  for (final v in [
                    c.name,
                    c.value,
                    c.domain ?? '—',
                    c.path ?? '/',
                    c.expires == null
                        ? 'Session'
                        : Formatters.dateTime(c.expires!),
                    c.httpOnly ? 'Yes' : 'No',
                    c.secure ? 'Yes' : 'No',
                  ])
                    Padding(
                      padding: const EdgeInsets.fromLTRB(0, 6, 18, 6),
                      child: Text(v, style: style),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _DetailsView extends StatelessWidget {
  const _DetailsView({required this.response});
  final ApiResponse response;

  @override
  Widget build(BuildContext context) => _KeyValueList(
    rows: [
      ('Method', response.method.value),
      ('Final URL', response.requestUrl),
      ('Status', '${response.statusCode} ${response.statusMessage}'),
      ('Duration', Formatters.duration(response.duration)),
      ('Body size', Formatters.bytes(response.bodySize)),
      ('Headers size', Formatters.bytes(response.headersSize)),
      ('Received at', Formatters.dateTime(response.receivedAt)),
      if (response.redirects.isNotEmpty)
        for (var i = 0; i < response.redirects.length; i++)
          ('Redirect ${i + 1}', response.redirects[i]),
    ],
  );
}
