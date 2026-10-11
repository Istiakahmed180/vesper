import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import 'variable_autocomplete.dart';
import 'variable_scope.dart';
import 'variable_text_controller.dart';

/// Single or multi-line text field with `{{variable}}` highlighting. It owns
/// its controller and only pushes changes outward via [onChanged]; external
/// value changes (e.g. URL → params sync) are applied when they differ from
/// what the user typed.
class VariableField extends ConsumerStatefulWidget {
  const VariableField({
    super.key,
    required this.value,
    required this.onChanged,
    this.hint,
    this.monospace = false,
    this.dense = true,
    this.focusNode,
    this.onSubmitted,
    this.obscure = false,
    this.maxLines = 1,
    this.borderless = false,
    this.autofocus = false,
    this.enabled = true,
    this.suggestCredentials = true,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final String? hint;
  final bool monospace;
  final bool dense;
  final FocusNode? focusNode;
  final ValueChanged<String>? onSubmitted;
  final bool obscure;
  final int? maxLines;
  final bool borderless;
  final bool autofocus;
  final bool enabled;

  /// Whether `{{` suggestions include token/password-like variables.
  final bool suggestCredentials;

  @override
  ConsumerState<VariableField> createState() => _VariableFieldState();
}

class _VariableFieldState extends ConsumerState<VariableField> {
  late final VariableTextController _controller;
  FocusNode? _ownFocus;

  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _controller = VariableTextController(
      text: widget.value,
      resolvedColor: Colors.teal,
      unresolvedColor: Colors.red,
    );
  }

  @override
  void didUpdateWidget(VariableField old) {
    super.didUpdateWidget(old);
    if (widget.value != _controller.text) {
      final selection = _controller.selection;
      _controller.value = TextEditingValue(
        text: widget.value,
        selection: selection.end <= widget.value.length
            ? selection
            : TextSelection.collapsed(offset: widget.value.length),
      );
    }
  }

  @override
  void dispose() {
    _ownFocus?.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final resolver = VariableScope.watch(ref, context);
    _controller
      ..resolvedColor = colors.variable
      ..unresolvedColor = colors.variableUnresolved
      ..isDefined = (name) => resolver.lookup(name) != null;

    final style = widget.monospace
        ? AppTheme.mono(context, size: 12.5)
        : TextStyle(fontSize: 13, color: colors.textPrimary);

    final field = TextField(
      controller: _controller,
      focusNode: _focus,
      autofocus: widget.autofocus,
      enabled: widget.enabled,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      obscureText: widget.obscure,
      maxLines: widget.obscure ? 1 : widget.maxLines,
      minLines: 1,
      style: style,
      cursorWidth: 1.5,
      decoration: InputDecoration(
        hintText: widget.hint,
        isDense: widget.dense,
        filled: !widget.borderless,
        border: widget.borderless ? InputBorder.none : null,
        enabledBorder: widget.borderless ? InputBorder.none : null,
        focusedBorder: widget.borderless ? InputBorder.none : null,
        contentPadding: widget.borderless
            ? const EdgeInsets.symmetric(horizontal: 8, vertical: 8)
            : null,
      ),
    );
    return VariableAutocomplete(
      controller: _controller,
      focusNode: _focus,
      onChanged: widget.onChanged,
      hideCredentials: !widget.suggestCredentials,
      child: field,
    );
  }
}
