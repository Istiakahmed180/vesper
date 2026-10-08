import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../features/api_client/presentation/response/body_formatter.dart';
import 'syntax_highlighter.dart';

class SearchMatch {
  const SearchMatch(this.line, this.start, this.length);
  final int line;
  final int start;
  final int length;
}

/// State of a [CodeView]: folding, search and scroll position.
class CodeViewController extends ChangeNotifier {
  CodeViewController(this._body) {
    _recomputeVisible();
  }

  FormattedBody _body;
  final Set<int> _collapsed = {};
  List<int> _visible = const [];
  String _query = '';
  List<SearchMatch> _matches = const [];
  Map<int, List<SearchMatch>> _matchesByLine = const {};
  int _current = -1;

  /// Set by the view; used to scroll to the current match.
  void Function(int visibleIndex)? _scrollTo;

  FormattedBody get body => _body;
  List<int> get visible => _visible;
  Set<int> get collapsed => _collapsed;
  String get query => _query;
  List<SearchMatch> get matches => _matches;
  int get currentMatch => _current;
  bool get hasFolds => _body.foldEnd.any((e) => e != -1);

  set body(FormattedBody value) {
    if (identical(value, _body)) return;
    _body = value;
    _collapsed.clear();
    _recomputeVisible();
    if (_query.isNotEmpty) {
      search(_query);
    } else {
      notifyListeners();
    }
  }

  List<SearchMatch> matchesOnLine(int line) => _matchesByLine[line] ?? const [];

  bool isCollapsed(int line) => _collapsed.contains(line);

  void toggleFold(int line) {
    if (_body.foldEnd[line] == -1) return;
    if (!_collapsed.remove(line)) _collapsed.add(line);
    _recomputeVisible();
    notifyListeners();
  }

  void expandAll() {
    _collapsed.clear();
    _recomputeVisible();
    notifyListeners();
  }

  /// Collapses every block except the outermost one.
  void collapseAll() {
    _collapsed.clear();
    for (var i = 1; i < _body.foldEnd.length; i++) {
      if (_body.foldEnd[i] != -1) _collapsed.add(i);
    }
    _recomputeVisible();
    notifyListeners();
  }

  void search(String query) {
    _query = query;
    if (query.isEmpty) {
      _matches = const [];
      _matchesByLine = const {};
      _current = -1;
      notifyListeners();
      return;
    }
    final needle = query.toLowerCase();
    final matches = <SearchMatch>[];
    final lines = _body.lines;
    for (var i = 0; i < lines.length && matches.length < 10000; i++) {
      final hay = lines[i].toLowerCase();
      var from = 0;
      while (true) {
        final idx = hay.indexOf(needle, from);
        if (idx == -1) break;
        matches.add(SearchMatch(i, idx, needle.length));
        from = idx + math.max(1, needle.length);
      }
    }
    _matches = matches;
    final byLine = <int, List<SearchMatch>>{};
    for (final m in matches) {
      byLine.putIfAbsent(m.line, () => []).add(m);
    }
    _matchesByLine = byLine;
    _current = matches.isEmpty ? -1 : 0;
    if (_current != -1) _reveal(matches[_current].line);
    notifyListeners();
  }

  void nextMatch([int delta = 1]) {
    if (_matches.isEmpty) return;
    _current = (_current + delta) % _matches.length;
    if (_current < 0) _current += _matches.length;
    _reveal(_matches[_current].line);
    notifyListeners();
  }

  void _reveal(int line) {
    final toOpen = _collapsed
        .where((s) => s < line && _body.foldEnd[s] >= line)
        .toList();
    if (toOpen.isNotEmpty) {
      _collapsed.removeAll(toOpen);
      _recomputeVisible();
    }
    final index = _visible.indexOf(line);
    if (index != -1) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollTo?.call(index),
      );
    }
  }

  void _recomputeVisible() {
    final n = _body.lines.length;
    if (_collapsed.isEmpty) {
      _visible = List<int>.generate(n, (i) => i);
      return;
    }
    final out = <int>[];
    var i = 0;
    while (i < n) {
      out.add(i);
      final end = _body.foldEnd[i];
      i = _collapsed.contains(i) && end > i ? end + 1 : i + 1;
    }
    _visible = out;
  }
}

/// Virtualised, read-only code viewer with line numbers, folding, syntax
/// highlighting and search highlights. Only visible rows are built.
class CodeView extends StatefulWidget {
  const CodeView({super.key, required this.controller, this.fontSize = 12.5});

  final CodeViewController controller;
  final double fontSize;

  @override
  State<CodeView> createState() => _CodeViewState();
}

class _CodeViewState extends State<CodeView> {
  final _vertical = ScrollController();
  final _horizontal = ScrollController();

  double get _lineHeight => (widget.fontSize * 1.6).roundToDouble();

  @override
  void initState() {
    super.initState();
    widget.controller._scrollTo = _scrollTo;
  }

  @override
  void didUpdateWidget(CodeView old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller._scrollTo = null;
      widget.controller._scrollTo = _scrollTo;
    }
  }

  @override
  void dispose() {
    widget.controller._scrollTo = null;
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  void _scrollTo(int index) {
    if (!_vertical.hasClients) return;
    final viewport = _vertical.position.viewportDimension;
    final target = (index * _lineHeight - viewport / 3).clamp(
      0.0,
      _vertical.position.maxScrollExtent,
    );
    _vertical.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final style = AppTheme.mono(
      context,
      size: widget.fontSize,
    ).copyWith(height: 1.6);
    final highlighter = SyntaxHighlighter(colors);
    final charWidth = _measureCharWidth(style);

    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        final body = c.body;
        final digits = body.lines.length.toString().length;
        final gutter = digits * charWidth + 34;
        final renderedChars = math.min(
          body.maxLineLength,
          AppConstants.maxRenderedLineLength + 40,
        );
        final contentWidth = gutter + renderedChars * charWidth + 48;
        final currentMatch =
            c.currentMatch >= 0 && c.currentMatch < c.matches.length
            ? c.matches[c.currentMatch]
            : null;

        return LayoutBuilder(
          builder: (context, constraints) {
            final width = math.max(constraints.maxWidth, contentWidth);
            return Scrollbar(
              controller: _horizontal,
              thumbVisibility: contentWidth > constraints.maxWidth,
              notificationPredicate: (n) => n.depth == 0,
              child: SingleChildScrollView(
                controller: _horizontal,
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: width,
                  child: Scrollbar(
                    controller: _vertical,
                    child: SelectionArea(
                      child: ListView.builder(
                        controller: _vertical,
                        itemExtent: _lineHeight,
                        itemCount: c.visible.length,
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        itemBuilder: (context, index) {
                          final line = c.visible[index];
                          return _CodeLine(
                            line: line,
                            text: body.lines[line],
                            language: body.language,
                            highlighter: highlighter,
                            style: style,
                            gutterWidth: gutter,
                            foldable: body.foldEnd[line] != -1,
                            collapsed: c.isCollapsed(line),
                            closingText: c.isCollapsed(line)
                                ? body.lines[body.foldEnd[line]].trim()
                                : null,
                            hiddenCount: c.isCollapsed(line)
                                ? body.foldEnd[line] - line - 1
                                : 0,
                            matches: c.matchesOnLine(line),
                            currentMatch: currentMatch?.line == line
                                ? currentMatch
                                : null,
                            onToggle: () => c.toggleFold(line),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  static double _measureCharWidth(TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: 'MMMMMMMMMM', style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final w = painter.width / 10;
    painter.dispose();
    return w;
  }
}

class _CodeLine extends StatelessWidget {
  const _CodeLine({
    required this.line,
    required this.text,
    required this.language,
    required this.highlighter,
    required this.style,
    required this.gutterWidth,
    required this.foldable,
    required this.collapsed,
    required this.closingText,
    required this.hiddenCount,
    required this.matches,
    required this.currentMatch,
    required this.onToggle,
  });

  final int line;
  final String text;
  final CodeLanguage language;
  final SyntaxHighlighter highlighter;
  final TextStyle style;
  final double gutterWidth;
  final bool foldable;
  final bool collapsed;
  final String? closingText;
  final int hiddenCount;
  final List<SearchMatch> matches;
  final SearchMatch? currentMatch;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    const limit = AppConstants.maxRenderedLineLength;
    final clipped = text.length > limit;
    final visibleText = clipped ? text.substring(0, limit) : text;

    var spans = highlighter.highlight(visibleText, language);
    if (matches.isNotEmpty) {
      spans = _applyMatches(spans, visibleText, colors);
    }

    return Row(
      children: [
        SelectionContainer.disabled(
          child: SizedBox(
            width: gutterWidth,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${line + 1}',
                    textAlign: TextAlign.right,
                    style: style.copyWith(
                      color: colors.textMuted,
                      fontSize: style.fontSize! - 1,
                    ),
                  ),
                ),
                SizedBox(
                  width: 22,
                  child: foldable
                      ? InkWell(
                          onTap: onToggle,
                          child: Icon(
                            collapsed ? Icons.chevron_right : Icons.expand_more,
                            size: 14,
                            color: colors.textMuted,
                          ),
                        )
                      : null,
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Text.rich(
            TextSpan(
              style: style,
              children: [
                ...spans,
                if (collapsed) ...[
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: SelectionContainer.disabled(
                      child: GestureDetector(
                        onTap: onToggle,
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          padding: const EdgeInsets.symmetric(horizontal: 5),
                          decoration: BoxDecoration(
                            color: colors.panelRaised,
                            borderRadius: BorderRadius.circular(3),
                            border: Border.all(color: colors.border),
                          ),
                          child: Text(
                            '$hiddenCount lines',
                            style: TextStyle(
                              fontSize: 10.5,
                              color: colors.textMuted,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  TextSpan(
                    text: closingText,
                    style: TextStyle(color: colors.syntaxPunctuation),
                  ),
                ],
                if (clipped)
                  TextSpan(
                    text:
                        '  … ${text.length - limit} more characters (use Copy to get the full line)',
                    style: TextStyle(
                      color: colors.textMuted,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
              ],
            ),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
          ),
        ),
      ],
    );
  }

  /// Splits highlighted spans so search matches get a background colour.
  List<TextSpan> _applyMatches(
    List<TextSpan> spans,
    String visibleText,
    VesperColors colors,
  ) {
    final marks = List<int>.filled(visibleText.length, 0);
    for (final m in matches) {
      final isCurrent = identical(m, currentMatch);
      for (var i = m.start; i < m.start + m.length && i < marks.length; i++) {
        marks[i] = isCurrent ? 2 : 1;
      }
    }
    final out = <TextSpan>[];
    var offset = 0;
    for (final span in spans) {
      final t = span.text ?? '';
      var segStart = 0;
      for (var i = 1; i <= t.length; i++) {
        final atEnd = i == t.length;
        if (atEnd || marks[offset + i] != marks[offset + segStart]) {
          final mark = marks.isEmpty || offset + segStart >= marks.length
              ? 0
              : marks[offset + segStart];
          out.add(
            TextSpan(
              text: t.substring(segStart, i),
              style: mark == 0
                  ? span.style
                  : (span.style ?? const TextStyle()).copyWith(
                      backgroundColor: mark == 2
                          ? colors.warning.withValues(alpha: 0.65)
                          : colors.searchHighlight,
                    ),
            ),
          );
          segStart = i;
        }
      }
      offset += t.length;
    }
    return out;
  }
}
