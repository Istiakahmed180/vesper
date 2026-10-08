import 'package:flutter/painting.dart';

import '../../../core/theme/app_colors.dart';
import '../../../features/api_client/presentation/response/body_formatter.dart';

/// Per-line tokenizer producing coloured spans. Works on single lines so it
/// can be applied lazily to only the rows currently on screen.
class SyntaxHighlighter {
  const SyntaxHighlighter(this.colors);

  final VesperColors colors;

  static final _json = RegExp(
    r'("(?:[^"\\]|\\.)*")(\s*:)?|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)|\b(true|false)\b|\b(null)\b|([{}\[\],:])',
  );

  static final _markup = RegExp(
    r'(<!--.*?-->)|(</?)([\w:.-]+)|([\w:.-]+)(=)("[^"]*"|'
    "'[^']*')"
    r'|(/?>)',
  );

  List<TextSpan> highlight(String line, CodeLanguage language) =>
      switch (language) {
        CodeLanguage.json => _highlightJson(line),
        CodeLanguage.xml || CodeLanguage.html => _highlightMarkup(line),
        CodeLanguage.text => [TextSpan(text: line)],
      };

  List<TextSpan> _highlightJson(String line) {
    final spans = <TextSpan>[];
    var last = 0;
    for (final m in _json.allMatches(line)) {
      if (m.start > last) {
        spans.add(TextSpan(text: line.substring(last, m.start)));
      }
      if (m.group(1) != null) {
        final isKey = m.group(2) != null;
        spans.add(
          TextSpan(
            text: m.group(1),
            style: TextStyle(
              color: isKey ? colors.syntaxKey : colors.syntaxString,
            ),
          ),
        );
        if (isKey) {
          spans.add(
            TextSpan(
              text: m.group(2),
              style: TextStyle(color: colors.syntaxPunctuation),
            ),
          );
        }
      } else if (m.group(3) != null) {
        spans.add(
          TextSpan(
            text: m.group(3),
            style: TextStyle(color: colors.syntaxNumber),
          ),
        );
      } else if (m.group(4) != null) {
        spans.add(
          TextSpan(
            text: m.group(4),
            style: TextStyle(color: colors.syntaxBool),
          ),
        );
      } else if (m.group(5) != null) {
        spans.add(
          TextSpan(
            text: m.group(5),
            style: TextStyle(color: colors.syntaxNull),
          ),
        );
      } else {
        spans.add(
          TextSpan(
            text: m.group(0),
            style: TextStyle(color: colors.syntaxPunctuation),
          ),
        );
      }
      last = m.end;
    }
    if (last < line.length) spans.add(TextSpan(text: line.substring(last)));
    return spans;
  }

  List<TextSpan> _highlightMarkup(String line) {
    final spans = <TextSpan>[];
    var last = 0;
    for (final m in _markup.allMatches(line)) {
      if (m.start > last) {
        spans.add(TextSpan(text: line.substring(last, m.start)));
      }
      if (m.group(1) != null) {
        spans.add(
          TextSpan(
            text: m.group(1),
            style: TextStyle(color: colors.syntaxNull),
          ),
        );
      } else if (m.group(3) != null) {
        spans
          ..add(
            TextSpan(
              text: m.group(2),
              style: TextStyle(color: colors.syntaxPunctuation),
            ),
          )
          ..add(
            TextSpan(
              text: m.group(3),
              style: TextStyle(color: colors.syntaxKey),
            ),
          );
      } else if (m.group(4) != null) {
        spans
          ..add(
            TextSpan(
              text: m.group(4),
              style: TextStyle(color: colors.syntaxBool),
            ),
          )
          ..add(
            TextSpan(
              text: m.group(5),
              style: TextStyle(color: colors.syntaxPunctuation),
            ),
          )
          ..add(
            TextSpan(
              text: m.group(6),
              style: TextStyle(color: colors.syntaxString),
            ),
          );
      } else {
        spans.add(
          TextSpan(
            text: m.group(0),
            style: TextStyle(color: colors.syntaxPunctuation),
          ),
        );
      }
      last = m.end;
    }
    if (last < line.length) spans.add(TextSpan(text: line.substring(last)));
    return spans;
  }
}
