import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../../../../core/constants/app_constants.dart';
import '../../domain/models/api_response.dart';

enum CodeLanguage { json, xml, html, text }

enum BodyView { pretty, raw, preview }

/// Body text split into lines, plus fold ranges for the code viewer.
@immutable
class FormattedBody {
  const FormattedBody({
    required this.lines,
    required this.foldEnd,
    required this.language,
    required this.maxLineLength,
    this.notice,
  });

  final List<String> lines;

  /// For each line that opens a block, the index of its closing line, else -1.
  final Int32List foldEnd;
  final CodeLanguage language;
  final int maxLineLength;

  /// Explains a fallback (e.g. invalid JSON shown raw).
  final String? notice;

  String get text => lines.join('\n');

  static final empty = FormattedBody(
    lines: const [''],
    foldEnd: Int32List.fromList([-1]),
    language: CodeLanguage.text,
    maxLineLength: 0,
  );
}

class _FormatJob {
  const _FormatJob(this.bytes, this.kind, this.view, this.charset);
  final Uint8List bytes;
  final ResponseContentKind kind;
  final BodyView view;
  final String? charset;
}

/// Formats a response body off the UI isolate for anything non-trivial.
Future<FormattedBody> formatResponseBody(ApiResponse response, BodyView view) {
  final charset = RegExp(
    r'charset=([^;]+)',
    caseSensitive: false,
  ).firstMatch(response.contentType)?.group(1)?.trim().toLowerCase();
  final job = _FormatJob(
    response.bodyBytes,
    response.contentKind,
    view,
    charset,
  );
  if (response.bodySize < 32 * 1024) return Future.value(_format(job));
  return Isolate.run(() => _format(job));
}

/// Formats text from the request body editor (always synchronous, small).
FormattedBody formatText(
  String text,
  CodeLanguage language, {
  bool pretty = true,
}) {
  final bytes = Uint8List.fromList(utf8.encode(text));
  final kind = switch (language) {
    CodeLanguage.json => ResponseContentKind.json,
    CodeLanguage.xml => ResponseContentKind.xml,
    CodeLanguage.html => ResponseContentKind.html,
    CodeLanguage.text => ResponseContentKind.text,
  };
  return _format(
    _FormatJob(bytes, kind, pretty ? BodyView.pretty : BodyView.raw, null),
  );
}

FormattedBody _format(_FormatJob job) {
  final text = job.charset == 'iso-8859-1' || job.charset == 'latin1'
      ? latin1.decode(job.bytes, allowInvalid: true)
      : utf8.decode(job.bytes, allowMalformed: true);
  final language = switch (job.kind) {
    ResponseContentKind.json => CodeLanguage.json,
    ResponseContentKind.xml => CodeLanguage.xml,
    ResponseContentKind.html => CodeLanguage.html,
    _ => CodeLanguage.text,
  };

  if (job.view == BodyView.raw) {
    return _fromText(text, CodeLanguage.text, fold: false);
  }

  if (job.bytes.length > AppConstants.maxPrettyBytes) {
    return _fromText(
      text,
      CodeLanguage.text,
      fold: false,
      notice:
          'Body is larger than ${AppConstants.maxPrettyBytes ~/ (1024 * 1024)} MB; '
          'showing it without formatting.',
    );
  }

  switch (language) {
    case CodeLanguage.json:
      try {
        final decoded = jsonDecode(text);
        final pretty = const JsonEncoder.withIndent('  ').convert(decoded);
        return _fromText(pretty, CodeLanguage.json, fold: true);
      } on FormatException {
        return _fromText(
          text,
          CodeLanguage.text,
          fold: false,
          notice: 'The body is not valid JSON; showing raw text.',
        );
      }
    case CodeLanguage.xml:
      return _fromText(_indentMarkup(text), CodeLanguage.xml, fold: true);
    case CodeLanguage.html:
      return _fromText(text, CodeLanguage.html, fold: false);
    case CodeLanguage.text:
      return _fromText(text, CodeLanguage.text, fold: false);
  }
}

FormattedBody _fromText(
  String text,
  CodeLanguage language, {
  required bool fold,
  String? notice,
}) {
  final lines = const LineSplitter().convert(text);
  if (lines.isEmpty) lines.add('');
  final foldEnd = Int32List(lines.length)..fillRange(0, lines.length, -1);
  var maxLen = 0;
  for (final l in lines) {
    if (l.length > maxLen) maxLen = l.length;
  }
  if (fold) {
    if (language == CodeLanguage.json) {
      final stack = <int>[];
      for (var i = 0; i < lines.length; i++) {
        final t = lines[i].trimRight();
        final trimmedLeft = t.trimLeft();
        if (trimmedLeft.startsWith('}') || trimmedLeft.startsWith(']')) {
          if (stack.isNotEmpty) {
            final start = stack.removeLast();
            if (i - start > 1) foldEnd[start] = i;
          }
        }
        if (t.endsWith('{') || t.endsWith('[')) stack.add(i);
      }
    } else if (language == CodeLanguage.xml) {
      final stack = <int>[];
      for (var i = 0; i < lines.length; i++) {
        final t = lines[i].trim();
        if (t.startsWith('</')) {
          if (stack.isNotEmpty) {
            final start = stack.removeLast();
            if (i - start > 1) foldEnd[start] = i;
          }
        } else if (t.startsWith('<') &&
            !t.startsWith('<?') &&
            !t.startsWith('<!') &&
            !t.endsWith('/>') &&
            !RegExp(r'</[^>]+>\s*$').hasMatch(t)) {
          stack.add(i);
        }
      }
    }
  }
  return FormattedBody(
    lines: lines,
    foldEnd: foldEnd,
    language: language,
    maxLineLength: maxLen,
    notice: notice,
  );
}

/// Lightweight XML pretty printer for minified documents. Already
/// multi-line documents are left untouched.
String _indentMarkup(String text) {
  final trimmed = text.trim();
  if (trimmed.contains('\n')) return text;
  final tokens = RegExp(r'(<[^>]+>)|([^<]+)').allMatches(trimmed);
  final out = StringBuffer();
  var depth = 0;
  String? pendingOpen;
  for (final m in tokens) {
    final tag = m.group(1);
    final content = m.group(2);
    if (tag != null) {
      final isClose = tag.startsWith('</');
      final isSelf =
          tag.endsWith('/>') || tag.startsWith('<?') || tag.startsWith('<!');
      if (isClose) {
        if (pendingOpen != null) {
          out.write(tag);
          pendingOpen = null;
          depth--;
          continue;
        }
        depth--;
        out.write('\n${'  ' * depth.clamp(0, 1000)}$tag');
      } else {
        if (pendingOpen != null) pendingOpen = null;
        if (out.isNotEmpty) out.write('\n');
        out.write('${'  ' * depth.clamp(0, 1000)}$tag');
        if (!isSelf) {
          depth++;
          pendingOpen = tag;
        }
      }
    } else if (content != null && content.trim().isNotEmpty) {
      if (pendingOpen != null) {
        out.write(content.trim());
      } else {
        out.write('\n${'  ' * depth.clamp(0, 1000)}${content.trim()}');
      }
    }
  }
  return out.toString();
}
