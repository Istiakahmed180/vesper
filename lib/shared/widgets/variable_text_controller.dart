import 'package:flutter/material.dart';

import '../../features/api_client/domain/services/variable_resolver.dart';

/// A [TextEditingController] that colours `{{variables}}`: resolved ones in
/// the variable colour, unknown ones in the error colour.
class VariableTextController extends TextEditingController {
  VariableTextController({
    super.text,
    required this.resolvedColor,
    required this.unresolvedColor,
    this.isDefined,
  });

  Color resolvedColor;
  Color unresolvedColor;

  /// Returns whether a variable exists in the current scope.
  bool Function(String name)? isDefined;

  /// Re-colour after the variable scope changed.
  void refresh() => notifyListeners();

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final text = value.text;
    if (!text.contains('{{') ||
        (withComposing && value.isComposingRangeValid)) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final spans = <TextSpan>[];
    var last = 0;
    for (final m in VariableResolver.pattern.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      final name = m.group(1)!;
      final defined = isDefined?.call(name) ?? false;
      final color = defined ? resolvedColor : unresolvedColor;
      spans.add(
        TextSpan(
          text: m.group(0),
          style: TextStyle(
            color: color,
            backgroundColor: color.withValues(alpha: 0.12),
            fontWeight: FontWeight.w500,
          ),
        ),
      );
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return TextSpan(style: style, children: spans);
  }
}
