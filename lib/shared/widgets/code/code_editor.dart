import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../features/api_client/domain/services/variable_resolver.dart';
import '../../../features/api_client/presentation/response/body_formatter.dart';
import '../../../features/environments/presentation/environment_providers.dart';
import 'syntax_highlighter.dart';

/// Controller that syntax-highlights its text and colours `{{variables}}`.
class CodeTextController extends TextEditingController {
  CodeTextController({super.text});

  CodeLanguage language = CodeLanguage.text;
  VesperColors? colors;
  bool Function(String name)? isDefined;

  /// Highlighting is skipped for very large texts to keep typing smooth.
  static const _maxHighlightLength = 200 * 1024;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final c = colors;
    if (c == null ||
        text.length > _maxHighlightLength ||
        (withComposing && value.isComposingRangeValid)) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final highlighter = SyntaxHighlighter(c);
    final children = <InlineSpan>[];
    var last = 0;
    void addCode(String segment) {
      final lines = segment.split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (i > 0) children.add(const TextSpan(text: '\n'));
        if (lines[i].isNotEmpty) {
          children.addAll(highlighter.highlight(lines[i], language));
        }
      }
    }

    for (final m in VariableResolver.pattern.allMatches(text)) {
      if (m.start > last) addCode(text.substring(last, m.start));
      final defined = isDefined?.call(m.group(1)!) ?? false;
      final color = defined ? c.variable : c.variableUnresolved;
      children.add(
        TextSpan(
          text: m.group(0),
          style: TextStyle(
            color: color,
            backgroundColor: color.withValues(alpha: 0.12),
          ),
        ),
      );
      last = m.end;
    }
    if (last < text.length) addCode(text.substring(last));
    return TextSpan(style: style, children: children);
  }
}

class _IndentIntent extends Intent {
  const _IndentIntent();
}

/// Multi-line code editor used for request bodies.
class CodeEditor extends ConsumerStatefulWidget {
  const CodeEditor({
    super.key,
    required this.value,
    required this.onChanged,
    this.language = CodeLanguage.text,
    this.hint,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final CodeLanguage language;
  final String? hint;

  @override
  ConsumerState<CodeEditor> createState() => _CodeEditorState();
}

class _CodeEditorState extends ConsumerState<CodeEditor> {
  late final CodeTextController _controller = CodeTextController(
    text: widget.value,
  );
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(CodeEditor old) {
    super.didUpdateWidget(old);
    if (widget.value != _controller.text) {
      _controller.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _indent() {
    final sel = _controller.selection;
    if (!sel.isValid) return;
    final text = _controller.text;
    final updated = text.replaceRange(sel.start, sel.end, '  ');
    _controller.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: sel.start + 2),
    );
    widget.onChanged(updated);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final resolver = ref.watch(variableResolverProvider);
    _controller
      ..language = widget.language
      ..colors = colors
      ..isDefined = (n) => resolver.lookup(n) != null;

    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.tab): _IndentIntent(),
      },
      child: Actions(
        actions: {
          _IndentIntent: CallbackAction<_IndentIntent>(
            onInvoke: (_) => _indent(),
          ),
        },
        child: Scrollbar(
          controller: _scroll,
          child: TextField(
            controller: _controller,
            scrollController: _scroll,
            onChanged: widget.onChanged,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            keyboardType: TextInputType.multiline,
            style: AppTheme.mono(context, size: 12.5),
            decoration: InputDecoration(
              hintText: widget.hint,
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: const EdgeInsets.all(12),
            ),
          ),
        ),
      ),
    );
  }
}

/// JSON helpers aware of `{{variables}}` (which make JSON technically invalid
/// when used as unquoted values, e.g. `"id": {{id}}`).
class JsonTools {
  const JsonTools._();

  static (String, Map<String, String>) _mask(String text) {
    final tokens = <String, String>{};
    var i = 0;
    final masked = text.replaceAllMapped(RegExp(r'("?)(\{\{[^{}]+\}\})("?)'), (
      m,
    ) {
      final quotedOpen = m.group(1)!.isNotEmpty;
      final quotedClose = m.group(3)!.isNotEmpty;
      final key = '__VESPER_VAR_${i++}__';
      tokens[key] = m.group(2)!;
      if (quotedOpen && quotedClose) return '"$key"';
      if (!quotedOpen && !quotedClose) return '"$key!"';
      return '${m.group(1)}$key${m.group(3)}';
    });
    return (masked, tokens);
  }

  static String _unmask(String text, Map<String, String> tokens) {
    var out = text;
    tokens.forEach((key, value) {
      out = out.replaceAll('"$key!"', value).replaceAll(key, value);
    });
    return out;
  }

  /// Returns an error message, or null when [text] is valid JSON.
  static String? validate(String text) {
    if (text.trim().isEmpty) return null;
    try {
      jsonDecode(_mask(text).$1);
      return null;
    } on FormatException catch (e) {
      final offset = e.offset;
      if (offset == null) return 'Invalid JSON';
      final before = text.substring(0, offset.clamp(0, text.length));
      final line = '\n'.allMatches(before).length + 1;
      return 'Invalid JSON near line $line: ${e.message}';
    }
  }

  /// Pretty-prints JSON while keeping variables intact. Throws [FormatException].
  static String beautify(String text) {
    final (masked, tokens) = _mask(text);
    final decoded = jsonDecode(masked);
    return _unmask(const JsonEncoder.withIndent('  ').convert(decoded), tokens);
  }
}
