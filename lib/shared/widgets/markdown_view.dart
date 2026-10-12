import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';

/// Renders the subset of GitHub-flavoured Markdown that shows up in release
/// notes: headings, paragraphs, lists (nested, ordered, task), blockquotes,
/// fenced code, rules, and inline bold / italic / strike / code / links.
class MarkdownView extends StatefulWidget {
  const MarkdownView(this.data, {super.key});

  final String data;

  @override
  State<MarkdownView> createState() => _MarkdownViewState();
}

class _MarkdownViewState extends State<MarkdownView> {
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final blocks = _parseBlocks(_stripComments(widget.data).split('\n'));
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _renderBlocks(
          context,
          blocks,
          TextStyle(
            fontSize: 13,
            height: 1.5,
            color: context.colors.textPrimary,
          ),
        ),
      ),
    );
  }

  List<Widget> _renderBlocks(
    BuildContext context,
    List<_Block> blocks,
    TextStyle base,
  ) {
    final out = <Widget>[];
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      final next = i + 1 < blocks.length ? blocks[i + 1] : null;
      // Consecutive list items sit tight; everything else gets a gap.
      final tight = block is _ListItem && next is _ListItem;
      out.add(
        Padding(
          padding: EdgeInsets.only(
            bottom: next == null ? 0 : (tight ? 3 : 10),
          ),
          child: _renderBlock(context, block, base),
        ),
      );
    }
    return out;
  }

  Widget _renderBlock(BuildContext context, _Block block, TextStyle base) {
    final colors = context.colors;
    switch (block) {
      case _Heading(:final level, :final text):
        final size = switch (level) {
          1 => 18.0,
          2 => 16.0,
          3 => 14.5,
          _ => 13.0,
        };
        return Padding(
          padding: EdgeInsets.only(top: level <= 2 ? 4 : 2),
          child: Text.rich(
            TextSpan(
              children: _inline(
                context,
                text,
                base.copyWith(fontSize: size, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        );
      case _Paragraph(:final text):
        return Text.rich(TextSpan(children: _inline(context, text, base)));
      case _ListItem(:final depth, :final marker, :final checked, :final text):
        final markerWidget = checked != null
            ? Icon(
                checked ? Icons.check_box : Icons.check_box_outline_blank,
                size: 14,
                color: checked ? colors.accent : colors.textMuted,
              )
            : Text(
                marker ?? (depth.isEven ? '•' : '◦'),
                style: base.copyWith(color: colors.textSecondary),
              );
        return Padding(
          padding: EdgeInsets.only(left: depth * 18.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: marker != null && marker.length > 2 ? 28 : 18,
                child: Padding(
                  padding: EdgeInsets.only(top: checked != null ? 3 : 0),
                  child: markerWidget,
                ),
              ),
              Expanded(
                child: Text.rich(
                  TextSpan(children: _inline(context, text, base)),
                ),
              ),
            ],
          ),
        );
      case _Quote(:final children):
        return Container(
          padding: const EdgeInsets.only(left: 12),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: colors.borderStrong, width: 3),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: _renderBlocks(
              context,
              children,
              base.copyWith(color: colors.textSecondary),
            ),
          ),
        );
      case _Code(:final text):
        return Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: colors.panelRaised,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: colors.border),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(text, style: AppTheme.mono(context, size: 12)),
          ),
        );
      case _Rule():
        return Divider(height: 1, color: colors.border);
    }
  }

  List<InlineSpan> _inline(BuildContext context, String text, TextStyle style) {
    final colors = context.colors;
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _inlinePattern.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start), style: style));
      }
      last = m.end;
      if (m.group(1) != null) {
        spans.add(
          TextSpan(
            text: m.group(1),
            style: AppTheme.mono(
              context,
              size: (style.fontSize ?? 13) - 1,
              color: style.color,
            ).copyWith(backgroundColor: colors.panelRaised),
          ),
        );
      } else if (m.group(2) != null) {
        spans.addAll(_link(context, m.group(2)!, m.group(3)!, style));
      } else if (m.group(4) != null || m.group(5) != null) {
        spans.addAll(
          _inline(
            context,
            m.group(4) ?? m.group(5)!,
            style.copyWith(fontWeight: FontWeight.w600),
          ),
        );
      } else if (m.group(6) != null) {
        spans.addAll(
          _inline(
            context,
            m.group(6)!,
            style.copyWith(decoration: TextDecoration.lineThrough),
          ),
        );
      } else if (m.group(7) != null || m.group(8) != null) {
        spans.addAll(
          _inline(
            context,
            m.group(7) ?? m.group(8)!,
            style.copyWith(fontStyle: FontStyle.italic),
          ),
        );
      } else if (m.group(9) != null) {
        final url = m.group(9)!;
        spans.addAll(_link(context, url, url, style));
      }
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last), style: style));
    }
    return spans;
  }

  List<InlineSpan> _link(
    BuildContext context,
    String label,
    String url,
    TextStyle style,
  ) {
    final uri = Uri.tryParse(url);
    final linkStyle = style.copyWith(
      color: context.colors.accent,
      decoration: TextDecoration.underline,
      decorationColor: context.colors.accent,
    );
    if (uri == null || !uri.hasScheme) {
      return _inline(context, label, linkStyle);
    }
    final recognizer = TapGestureRecognizer()
      ..onTap = () => launchUrl(uri, mode: LaunchMode.externalApplication);
    _recognizers.add(recognizer);
    return [
      TextSpan(
        style: linkStyle,
        recognizer: recognizer,
        mouseCursor: SystemMouseCursors.click,
        children: _inline(context, label, linkStyle),
      ),
    ];
  }
}

// Groups: 1 code, 2/3 link label/url (images render as links), 4/5 bold,
// 6 strike, 7/8 italic, 9 bare URL.
final _inlinePattern = RegExp(
  r'`([^`]+)`'
  r'|!?\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)'
  r'|\*\*(.+?)\*\*|__(.+?)__'
  r'|~~(.+?)~~'
  r'|\*(?=\S)(.+?)(?<=\S)\*|(?<![\w])_(?=\S)(.+?)(?<=\S)_(?![\w])'
  r'|(https?://[^\s<>()]+[^\s<>().,;:!?])',
);

String _stripComments(String s) =>
    s.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '').replaceAll('\r', '');

sealed class _Block {}

class _Heading extends _Block {
  _Heading(this.level, this.text);
  final int level;
  final String text;
}

class _Paragraph extends _Block {
  _Paragraph(this.text);
  final String text;
}

class _ListItem extends _Block {
  _ListItem(this.depth, this.marker, this.checked, this.text);
  final int depth;

  /// Ordered marker like `1.`; null for bullets.
  final String? marker;

  /// Task-list state; null when not a task item.
  final bool? checked;
  String text;
}

class _Quote extends _Block {
  _Quote(this.children);
  final List<_Block> children;
}

class _Code extends _Block {
  _Code(this.text);
  final String text;
}

class _Rule extends _Block {}

final _headingRe = RegExp(r'^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$');
final _ruleRe = RegExp(r'^\s{0,3}([-*_])(\s*\1){2,}\s*$');
final _quoteRe = RegExp(r'^\s{0,3}>\s?(.*)$');
final _listRe = RegExp(r'^(\s*)([-*+]|\d{1,9}[.)])\s+(.*)$');
final _fenceRe = RegExp(r'^\s{0,3}(`{3,}|~{3,})');
final _taskRe = RegExp(r'^\[([ xX])\]\s+(.*)$');

List<_Block> _parseBlocks(List<String> lines) {
  final blocks = <_Block>[];
  final para = <String>[];

  void flush() {
    if (para.isEmpty) return;
    blocks.add(_Paragraph(para.join('\n')));
    para.clear();
  }

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];

    final fence = _fenceRe.firstMatch(line);
    if (fence != null) {
      flush();
      final close = fence.group(1)!;
      final body = <String>[];
      i++;
      while (i < lines.length && !lines[i].trimLeft().startsWith(close)) {
        body.add(lines[i]);
        i++;
      }
      blocks.add(_Code(body.join('\n')));
      continue;
    }

    if (line.trim().isEmpty) {
      flush();
      continue;
    }

    final heading = _headingRe.firstMatch(line);
    if (heading != null) {
      flush();
      blocks.add(_Heading(heading.group(1)!.length, heading.group(2)!));
      continue;
    }

    if (_ruleRe.hasMatch(line)) {
      flush();
      blocks.add(_Rule());
      continue;
    }

    if (_quoteRe.hasMatch(line)) {
      flush();
      final inner = <String>[];
      while (i < lines.length) {
        final q = _quoteRe.firstMatch(lines[i]);
        if (q == null) break;
        inner.add(q.group(1)!);
        i++;
      }
      i--;
      blocks.add(_Quote(_parseBlocks(inner)));
      continue;
    }

    final item = _listRe.firstMatch(line);
    if (item != null) {
      flush();
      final indent = item.group(1)!.replaceAll('\t', '    ').length;
      final rawMarker = item.group(2)!;
      var text = item.group(3)!;
      bool? checked;
      final task = _taskRe.firstMatch(text);
      if (task != null) {
        checked = task.group(1)!.toLowerCase() == 'x';
        text = task.group(2)!;
      }
      blocks.add(
        _ListItem(
          (indent / 2).floor().clamp(0, 6),
          RegExp(r'^\d').hasMatch(rawMarker) ? rawMarker : null,
          checked,
          text,
        ),
      );
      continue;
    }

    // Lazy continuation of the previous list item.
    if (para.isEmpty && blocks.isNotEmpty && blocks.last is _ListItem) {
      final prev = i > 0 ? lines[i - 1] : '';
      if (prev.trim().isNotEmpty) {
        final last = blocks.last as _ListItem;
        last.text = '${last.text}\n${line.trim()}';
        continue;
      }
    }

    para.add(line.trim());
  }
  flush();
  return blocks;
}
