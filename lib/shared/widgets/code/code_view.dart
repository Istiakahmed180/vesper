import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../features/api_client/presentation/response/body_formatter.dart';
import 'syntax_highlighter.dart';

/// A caret position: [col] characters into body line [line].
@immutable
class CodePosition implements Comparable<CodePosition> {
  const CodePosition(this.line, this.col);
  final int line;
  final int col;

  @override
  int compareTo(CodePosition other) =>
      line != other.line ? line - other.line : col - other.col;

  bool operator <(CodePosition other) => compareTo(other) < 0;

  @override
  bool operator ==(Object other) =>
      other is CodePosition && other.line == line && other.col == col;

  @override
  int get hashCode => Object.hash(line, col);

  @override
  String toString() => 'CodePosition($line, $col)';
}

class SearchMatch {
  const SearchMatch(this.line, this.start, this.length);
  final int line;
  final int start;
  final int length;
}

/// State of a [CodeView]: folding, search, caret/selection and scroll
/// position. The selection is kept in body coordinates, so it covers lines
/// that are scrolled away or folded.
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
  CodePosition? _anchor;
  CodePosition? _caret;

  /// Set by the view; used to scroll to the current match.
  void Function(int visibleIndex)? _scrollTo;

  FormattedBody get body => _body;
  List<int> get visible => _visible;
  Set<int> get collapsed => _collapsed;
  String get query => _query;
  List<SearchMatch> get matches => _matches;
  int get currentMatch => _current;
  bool get hasFolds => _body.foldEnd.any((e) => e != -1);

  /// Where the caret is, or null before the first click.
  CodePosition? get caret => _caret;

  bool get hasSelection =>
      _anchor != null && _caret != null && _anchor != _caret;

  /// The selected range in reading order, or null when nothing is selected.
  (CodePosition, CodePosition)? get selection {
    if (!hasSelection) return null;
    return _anchor! < _caret! ? (_anchor!, _caret!) : (_caret!, _anchor!);
  }

  /// The selected text, including folded lines inside the selection.
  String get selectedText {
    final range = selection;
    if (range == null) return '';
    final (a, b) = range;
    final lines = _body.lines;
    if (a.line == b.line) return lines[a.line].substring(a.col, b.col);
    final out = StringBuffer(lines[a.line].substring(a.col));
    for (var i = a.line + 1; i < b.line; i++) {
      out
        ..write('\n')
        ..write(lines[i]);
    }
    out
      ..write('\n')
      ..write(lines[b.line].substring(0, b.col));
    return out.toString();
  }

  /// Columns selected on [line] as `(start, end)`; `end` is past the line's
  /// length when the line break is selected too.
  (int, int)? selectionOnLine(int line) {
    final range = selection;
    if (range == null) return null;
    final (a, b) = range;
    if (line < a.line || line > b.line) return null;
    final length = _body.lines[line].length;
    final start = line == a.line ? a.col : 0;
    final end = line == b.line ? b.col : length + 1;
    return start == end ? null : (start, end);
  }

  CodePosition _clamp(CodePosition p) {
    final line = p.line.clamp(0, _body.lines.length - 1);
    return CodePosition(line, p.col.clamp(0, _body.lines[line].length));
  }

  /// Moves the caret; with [extend] the selection grows from its anchor.
  void moveCaret(CodePosition position, {bool extend = false}) {
    final p = _clamp(position);
    if (!extend || _anchor == null) _anchor = p;
    _caret = p;
    notifyListeners();
  }

  /// Selects `[from, to)`, leaving the caret at [to].
  void select(CodePosition from, CodePosition to) {
    _anchor = _clamp(from);
    _caret = _clamp(to);
    notifyListeners();
  }

  void selectAll() {
    final last = _body.lines.length - 1;
    select(
      const CodePosition(0, 0),
      CodePosition(last, _body.lines[last].length),
    );
  }

  /// Keeps the caret, drops the selection.
  void collapseSelection() {
    if (_caret == null) return;
    _anchor = _caret;
    notifyListeners();
  }

  set body(FormattedBody value) {
    if (identical(value, _body)) return;
    _body = value;
    _collapsed.clear();
    _anchor = _caret = null;
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
/// highlighting and search highlights. Only visible rows are built; the caret
/// and selection live in [CodeViewController], so Select All and Copy cover
/// the whole body.
class CodeView extends StatefulWidget {
  const CodeView({
    super.key,
    required this.controller,
    this.fontSize = 12.5,
    this.extraMenuItems,
  });

  final CodeViewController controller;
  final double fontSize;

  /// Extra right-click entries for the selected text, after Copy etc.
  final List<ContextMenuButtonItem> Function(String selection)? extraMenuItems;

  @override
  State<CodeView> createState() => _CodeViewState();
}

class _CodeViewState extends State<CodeView> {
  static const _padTop = 6.0;
  static const _foldWidth = 22.0;

  final _vertical = ScrollController();
  final _horizontal = ScrollController();
  final _focus = FocusNode(debugLabel: 'CodeView');
  final _menu = ContextMenuController();
  final _caretVisible = ValueNotifier(true);
  Timer? _blink;

  // Multi-click detection (word / line selection).
  int _clicks = 0;
  DateTime _lastClick = DateTime(0);
  Offset _lastClickAt = Offset.zero;
  CodePosition? _dragOrigin;
  (CodePosition, CodePosition)? _dragUnit;

  // Layout of the last build, used for hit testing.
  double _gutter = 0;
  TextStyle _style = const TextStyle();

  CodeViewController get _c => widget.controller;

  double get _lineHeight => (widget.fontSize * 1.6).roundToDouble();

  @override
  void initState() {
    super.initState();
    _c._scrollTo = _scrollTo;
    _focus.addListener(_onFocus);
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
    _c._scrollTo = null;
    _blink?.cancel();
    _menu.remove();
    _focus.dispose();
    _caretVisible.dispose();
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  void _onFocus() {
    _blink?.cancel();
    _caretVisible.value = true;
    if (_focus.hasFocus) {
      _blink = Timer.periodic(
        const Duration(milliseconds: 530),
        (_) => _caretVisible.value = !_caretVisible.value,
      );
    }
    setState(() {});
  }

  void _restartBlink() {
    if (!_focus.hasFocus) return;
    _onFocus();
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

  /// Keeps the caret's line on screen after keyboard moves.
  void _revealCaret() {
    final caret = _c.caret;
    if (caret == null || !_vertical.hasClients) return;
    final index = _c.visible.indexOf(caret.line);
    if (index == -1) return;
    final top = index * _lineHeight + _padTop;
    final pos = _vertical.position;
    if (top < pos.pixels) {
      _vertical.jumpTo(top - _padTop);
    } else if (top + _lineHeight > pos.pixels + pos.viewportDimension) {
      _vertical.jumpTo(
        math.min(
          pos.maxScrollExtent,
          top + _lineHeight - pos.viewportDimension + _padTop,
        ),
      );
    }
  }

  // ------------------------------------------------------------ hit testing

  String _rendered(int line) {
    final text = _c.body.lines[line];
    const limit = AppConstants.maxRenderedLineLength;
    return text.length > limit ? text.substring(0, limit) : text;
  }

  TextPainter _painter(String text) => TextPainter(
    text: TextSpan(text: text, style: _style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();

  double _xOf(int line, int col) {
    final text = _rendered(line);
    if (col <= 0 || text.isEmpty) return 0;
    final painter = _painter(text);
    final x = painter
        .getOffsetForCaret(
          TextPosition(offset: math.min(col, text.length)),
          Rect.zero,
        )
        .dx;
    painter.dispose();
    return x;
  }

  /// Body position under [local] (relative to the viewer's viewport).
  CodePosition _positionAt(Offset local) {
    final visible = _c.visible;
    final y = local.dy + (_vertical.hasClients ? _vertical.offset : 0);
    final index = ((y - _padTop) / _lineHeight).floor();
    if (index < 0) return const CodePosition(0, 0);
    if (index >= visible.length) {
      final last = visible.last;
      return CodePosition(last, _c.body.lines[last].length);
    }
    final line = visible[index];
    final x =
        local.dx + (_horizontal.hasClients ? _horizontal.offset : 0) - _gutter;
    final text = _rendered(line);
    if (x <= 0 || text.isEmpty) return CodePosition(line, 0);
    final painter = _painter(text);
    final col = painter.getPositionForOffset(Offset(x, _lineHeight / 2)).offset;
    painter.dispose();
    return CodePosition(line, col);
  }

  (CodePosition, CodePosition) _wordAt(CodePosition p) {
    final text = _c.body.lines[p.line];
    bool isWord(int i) => RegExp(r'[\w$@.\-]').hasMatch(text[i]);
    var start = p.col;
    var end = p.col;
    if (start < text.length && isWord(start) ||
        start > 0 && isWord(start - 1)) {
      while (start > 0 && isWord(start - 1)) {
        start--;
      }
      while (end < text.length && isWord(end)) {
        end++;
      }
    } else if (end < text.length) {
      end++;
    }
    return (CodePosition(p.line, start), CodePosition(p.line, end));
  }

  (CodePosition, CodePosition) _lineAt(CodePosition p) {
    final last = _c.body.lines.length - 1;
    return (
      CodePosition(p.line, 0),
      p.line < last
          ? CodePosition(p.line + 1, 0)
          : CodePosition(p.line, _c.body.lines[p.line].length),
    );
  }

  // ------------------------------------------------------------------ mouse

  void _onPointerDown(PointerDownEvent e) {
    _menu.remove();
    final scrolledX = _horizontal.hasClients ? _horizontal.offset : 0.0;
    if (e.localPosition.dx + scrolledX < _gutter) return;
    _focus.requestFocus();
    final pos = _positionAt(e.localPosition);
    if (e.buttons == kSecondaryMouseButton) {
      final range = _c.selection;
      final inside = range != null && !(pos < range.$1) && pos < range.$2;
      if (!inside) _c.moveCaret(pos);
      return;
    }
    if (e.buttons != kPrimaryMouseButton) return;

    final now = DateTime.now();
    final again =
        now.difference(_lastClick) < const Duration(milliseconds: 400) &&
        (e.localPosition - _lastClickAt).distance < 6;
    _clicks = again ? _clicks % 3 + 1 : 1;
    _lastClick = now;
    _lastClickAt = e.localPosition;

    final shift = HardwareKeyboard.instance.isShiftPressed;
    _dragUnit = null;
    switch (_clicks) {
      case 2:
        _dragUnit = _wordAt(pos);
        _c.select(_dragUnit!.$1, _dragUnit!.$2);
      case 3:
        _dragUnit = _lineAt(pos);
        _c.select(_dragUnit!.$1, _dragUnit!.$2);
      default:
        _c.moveCaret(pos, extend: shift);
    }
    _dragOrigin = pos;
    _restartBlink();
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (_dragOrigin == null || e.buttons != kPrimaryMouseButton) return;
    // Scroll while dragging past the top or bottom edge.
    if (_vertical.hasClients) {
      final h = _vertical.position.viewportDimension;
      final dy = e.localPosition.dy < 0
          ? e.localPosition.dy
          : e.localPosition.dy > h
          ? e.localPosition.dy - h
          : 0.0;
      if (dy != 0) {
        _vertical.jumpTo(
          (_vertical.offset + dy).clamp(0, _vertical.position.maxScrollExtent),
        );
      }
    }
    final pos = _positionAt(e.localPosition);
    final unit = _dragUnit;
    if (unit == null) {
      _c.moveCaret(pos, extend: true);
    } else {
      final at = _clicks == 2 ? _wordAt(pos) : _lineAt(pos);
      if (at.$1 < unit.$1) {
        _c.select(unit.$2, at.$1);
      } else {
        _c.select(unit.$1, at.$2);
      }
    }
    _restartBlink();
  }

  void _onPointerUp(PointerUpEvent e) {
    _dragOrigin = null;
  }

  // --------------------------------------------------------------- keyboard

  Future<void> _copy() async {
    final text = _c.selectedText;
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final primary = Platform.isMacOS
        ? keys.isMetaPressed
        : keys.isControlPressed;
    final shift = keys.isShiftPressed;
    final key = event.logicalKey;

    if (primary && key == LogicalKeyboardKey.keyA) {
      _c.selectAll();
      return KeyEventResult.handled;
    }
    if (primary && key == LogicalKeyboardKey.keyC) {
      unawaited(_copy());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape && _c.hasSelection) {
      _c.collapseSelection();
      return KeyEventResult.handled;
    }

    final caret = _c.caret;
    if (caret == null) return KeyEventResult.ignored;
    final lines = _c.body.lines;
    final visible = _c.visible;
    CodePosition vertical(int delta) {
      final index = visible.indexOf(caret.line);
      final next = visible[(index + delta).clamp(0, visible.length - 1)];
      return CodePosition(next, math.min(caret.col, lines[next].length));
    }

    final range = _c.selection;
    final CodePosition? target = switch (key) {
      LogicalKeyboardKey.arrowLeft =>
        range != null && !shift
            ? range.$1
            : caret.col > 0
            ? CodePosition(caret.line, caret.col - 1)
            : caret.line > 0
            ? CodePosition(caret.line - 1, lines[caret.line - 1].length)
            : caret,
      LogicalKeyboardKey.arrowRight =>
        range != null && !shift
            ? range.$2
            : caret.col < lines[caret.line].length
            ? CodePosition(caret.line, caret.col + 1)
            : caret.line < lines.length - 1
            ? CodePosition(caret.line + 1, 0)
            : caret,
      LogicalKeyboardKey.arrowUp => vertical(-1),
      LogicalKeyboardKey.arrowDown => vertical(1),
      LogicalKeyboardKey.pageUp => vertical(-20),
      LogicalKeyboardKey.pageDown => vertical(20),
      LogicalKeyboardKey.home => CodePosition(caret.line, 0),
      LogicalKeyboardKey.end => CodePosition(
        caret.line,
        lines[caret.line].length,
      ),
      _ => null,
    };
    if (target == null) return KeyEventResult.ignored;
    _c.moveCaret(target, extend: shift);
    _restartBlink();
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealCaret());
    return KeyEventResult.handled;
  }

  // ------------------------------------------------------------ context menu

  void _showMenu(Offset globalPosition) {
    final selected = _c.selectedText;
    _menu.show(
      context: context,
      contextMenuBuilder: (context) => AdaptiveTextSelectionToolbar.buttonItems(
        anchors: TextSelectionToolbarAnchors(primaryAnchor: globalPosition),
        buttonItems: [
          if (selected.isNotEmpty)
            ContextMenuButtonItem(
              type: ContextMenuButtonType.copy,
              onPressed: () {
                _menu.remove();
                unawaited(_copy());
              },
            ),
          ContextMenuButtonItem(
            type: ContextMenuButtonType.selectAll,
            onPressed: () {
              _menu.remove();
              _c.selectAll();
            },
          ),
          ...?widget.extraMenuItems?.call(selected),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final style = _style = AppTheme.mono(
      context,
      size: widget.fontSize,
    ).copyWith(height: 1.6);
    final highlighter = SyntaxHighlighter(colors);
    final charWidth = _measureCharWidth(style);
    final selectionColor = colors.accent.withValues(alpha: 0.32);

    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        final body = c.body;
        final digits = body.lines.length.toString().length;
        final gutter = _gutter = digits * charWidth + 12 + _foldWidth;
        final renderedChars = math.min(
          body.maxLineLength,
          AppConstants.maxRenderedLineLength + 40,
        );
        final contentWidth = gutter + renderedChars * charWidth + 48;
        final currentMatch =
            c.currentMatch >= 0 && c.currentMatch < c.matches.length
            ? c.matches[c.currentMatch]
            : null;
        final caret = _focus.hasFocus ? c.caret : null;

        return LayoutBuilder(
          builder: (context, constraints) {
            final width = math.max(constraints.maxWidth, contentWidth);
            return Focus(
              focusNode: _focus,
              onKeyEvent: _onKey,
              child: Listener(
                onPointerDown: _onPointerDown,
                onPointerMove: _onPointerMove,
                onPointerUp: _onPointerUp,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onSecondaryTapUp: (d) => _showMenu(d.globalPosition),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.text,
                    child: Scrollbar(
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
                            child: ListView.builder(
                              controller: _vertical,
                              itemExtent: _lineHeight,
                              itemCount: c.visible.length,
                              padding: const EdgeInsets.symmetric(
                                vertical: _padTop,
                              ),
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
                                  selected: c.selectionOnLine(line),
                                  selectionColor: selectionColor,
                                  caretX: caret?.line == line
                                      ? _xOf(line, caret!.col)
                                      : null,
                                  caretVisible: _caretVisible,
                                  onToggle: () => c.toggleFold(line),
                                );
                              },
                            ),
                          ),
                        ),
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
    required this.selected,
    required this.selectionColor,
    required this.caretX,
    required this.caretVisible,
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

  /// Selected columns on this line; an end past the text selects the break.
  final (int, int)? selected;
  final Color selectionColor;

  /// Caret offset from the start of the text, when the caret is here.
  final double? caretX;
  final ValueListenable<bool> caretVisible;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    const limit = AppConstants.maxRenderedLineLength;
    final clipped = text.length > limit;
    final visibleText = clipped ? text.substring(0, limit) : text;

    var spans = highlighter.highlight(visibleText, language);
    if (matches.isNotEmpty || selected != null) {
      spans = _applyMarks(spans, visibleText, colors);
    }
    final selectsBreak = selected != null && selected!.$2 > text.length;

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
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Text.rich(
                TextSpan(
                  style: style,
                  children: [
                    ...spans,
                    if (selectsBreak)
                      TextSpan(
                        text: ' ',
                        style: TextStyle(backgroundColor: selectionColor),
                      ),
                    if (collapsed) ...[
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: SelectionContainer.disabled(
                          child: GestureDetector(
                            onTap: onToggle,
                            child: Container(
                              margin: const EdgeInsets.symmetric(horizontal: 4),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                              ),
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
              if (caretX != null)
                Positioned(
                  left: caretX,
                  top: 2,
                  bottom: 2,
                  child: ValueListenableBuilder<bool>(
                    valueListenable: caretVisible,
                    builder: (context, bool visible, _) => Container(
                      width: 1.5,
                      color: visible ? colors.textPrimary : Colors.transparent,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// Splits highlighted spans so the selection and search matches get a
  /// background colour.
  List<TextSpan> _applyMarks(
    List<TextSpan> spans,
    String visibleText,
    VesperColors colors,
  ) {
    // 0 = plain, 1 = match, 2 = selected, 3 = current match.
    final marks = List<int>.filled(visibleText.length, 0);
    final sel = selected;
    if (sel != null) {
      for (var i = sel.$1; i < sel.$2 && i < marks.length; i++) {
        marks[i] = 2;
      }
    }
    for (final m in matches) {
      final isCurrent = identical(m, currentMatch);
      for (var i = m.start; i < m.start + m.length && i < marks.length; i++) {
        if (isCurrent) {
          marks[i] = 3;
        } else if (marks[i] == 0) {
          marks[i] = 1;
        }
      }
    }
    Color? background(int mark) => switch (mark) {
      1 => colors.searchHighlight,
      2 => selectionColor,
      3 => colors.warning.withValues(alpha: 0.65),
      _ => null,
    };
    final out = <TextSpan>[];
    var offset = 0;
    for (final span in spans) {
      final t = span.text ?? '';
      var segStart = 0;
      for (var i = 1; i <= t.length; i++) {
        final atEnd = i == t.length;
        if (atEnd || marks[offset + i] != marks[offset + segStart]) {
          final mark = offset + segStart >= marks.length
              ? 0
              : marks[offset + segStart];
          final bg = background(mark);
          out.add(
            TextSpan(
              text: t.substring(segStart, i),
              style: bg == null
                  ? span.style
                  : (span.style ?? const TextStyle()).copyWith(
                      backgroundColor: bg,
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
