import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/security/redactor.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../features/api_client/domain/services/variable_resolver.dart';
import '../../features/environments/presentation/environment_providers.dart';

/// An unfinished `{{name` the cursor is currently in.
@immutable
class VariableToken {
  const VariableToken(this.start, this.end, this.query);

  /// Index of the opening `{{`.
  final int start;

  /// Cursor position.
  final int end;

  /// What was typed after `{{`.
  final String query;

  /// Finds the token being typed at [cursor], if any.
  static VariableToken? at(String text, int cursor) {
    if (cursor < 2 || cursor > text.length) return null;
    final before = text.substring(0, cursor);
    final open = before.lastIndexOf('{{');
    if (open == -1) return null;
    final query = before.substring(open + 2);
    if (query.contains(RegExp(r'[{}\s]'))) return null;
    return VariableToken(open, cursor, query);
  }

  /// Replaces the token with `{{name}}`, swallowing the rest of a name and
  /// closing braces that were already there. Returns the new value.
  TextEditingValue complete(String text, String name) {
    var replaceEnd = end;
    final rest = RegExp(r'^[^{}\s]*\}\}').firstMatch(text.substring(end));
    if (rest != null) replaceEnd += rest.end;
    final inserted = '{{$name}}';
    final updated = text.replaceRange(start, replaceEnd, inserted);
    return TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: start + inserted.length),
    );
  }
}

@immutable
class VariableSuggestion {
  const VariableSuggestion(this.name, this.source, this.preview);
  final String name;
  final String source;
  final String preview;
}

/// Suggestions for [query] from the active environment, globals and the
/// dynamic variables, best matches first.
List<VariableSuggestion> variableSuggestions(
  String query,
  VariableResolver resolver, {
  String? environmentName,
  int limit = 8,
}) {
  final q = query.toLowerCase();
  final all = <String, VariableSuggestion>{};
  String preview(VariableValue v) {
    if (v.isSecret) return Redactor.mask;
    return v.value.length > 48 ? '${v.value.substring(0, 48)}…' : v.value;
  }

  // Globals first so environment values (which win at runtime) replace them.
  for (final e in resolver.globals.entries) {
    all[e.key] = VariableSuggestion(e.key, 'Globals', preview(e.value));
  }
  for (final e in resolver.environment.entries) {
    all[e.key] = VariableSuggestion(
      e.key,
      environmentName ?? 'Environment',
      preview(e.value),
    );
  }
  for (final e in VariableResolver.dynamicVariables.entries) {
    all[e.key] = VariableSuggestion(e.key, 'Dynamic', e.value);
  }

  int rank(String name) {
    final n = name.toLowerCase();
    if (n.startsWith(q)) return 0;
    if (n.contains(q)) return 1;
    return 2;
  }

  final matches = all.values.where((s) => rank(s.name) < 2).toList()
    ..sort((a, b) {
      final r = rank(a.name).compareTo(rank(b.name));
      if (r != 0) return r;
      // Dynamic variables after user-defined ones.
      final d = a.name.startsWith(r'$') == b.name.startsWith(r'$')
          ? 0
          : (a.name.startsWith(r'$') ? 1 : -1);
      return d != 0 ? d : a.name.compareTo(b.name);
    });
  return matches.take(limit).toList();
}

/// Shows `{{variable}}` suggestions under a text field while the user types
/// `{{`. Arrow keys move, Enter/Tab insert, Escape dismisses.
class VariableAutocomplete extends ConsumerStatefulWidget {
  const VariableAutocomplete({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.child,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final Widget child;

  @override
  ConsumerState<VariableAutocomplete> createState() =>
      _VariableAutocompleteState();
}

class _VariableAutocompleteState extends ConsumerState<VariableAutocomplete> {
  final _link = LayerLink();
  final _portal = OverlayPortalController();
  VariableToken? _token;
  List<VariableSuggestion> _options = const [];
  int _highlighted = 0;

  /// Token the user dismissed with Escape; hidden until they type more.
  VariableToken? _dismissed;

  /// Position of the list relative to the field (updated after layout).
  Offset? _anchor;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_update);
    widget.focusNode.addListener(_update);
  }

  @override
  void didUpdateWidget(VariableAutocomplete old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_update);
      widget.controller.addListener(_update);
    }
    if (old.focusNode != widget.focusNode) {
      old.focusNode.removeListener(_update);
      widget.focusNode.addListener(_update);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_update);
    widget.focusNode.removeListener(_update);
    super.dispose();
  }

  void _update() {
    // Text can change during a build (e.g. the field syncing an external
    // value); recompute after the frame in that case.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) _recompute();
      });
      return;
    }
    _recompute();
  }

  void _recompute() {
    final value = widget.controller.value;
    final cursor = value.selection.isCollapsed
        ? value.selection.baseOffset
        : -1;
    final token = widget.focusNode.hasFocus && cursor >= 0
        ? VariableToken.at(value.text, cursor)
        : null;
    final dismissed = _dismissed;
    if (token == null ||
        dismissed == null ||
        token.start != dismissed.start ||
        token.query != dismissed.query) {
      _dismissed = null;
    }
    final options = token == null || _dismissed != null
        ? const <VariableSuggestion>[]
        : variableSuggestions(
            token.query,
            ref.read(variableResolverProvider),
            environmentName: ref.read(activeEnvironmentProvider)?.name,
          );
    final queryChanged = token?.query != _token?.query;
    setState(() {
      _token = token;
      _options = options;
      if (queryChanged || _highlighted >= options.length) _highlighted = 0;
    });
    if (options.isEmpty) {
      if (_portal.isShowing) _portal.hide();
      return;
    }
    if (!_portal.isShowing) _portal.show();
    // The caret position is only known once the new text is laid out.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _token == null) return;
      final anchor = _anchorOffset();
      if (anchor != _anchor) setState(() => _anchor = anchor);
    });
  }

  bool get _visible => _options.isNotEmpty;

  void _move(int delta) => setState(() {
    _highlighted = (_highlighted + delta) % _options.length;
    if (_highlighted < 0) _highlighted += _options.length;
  });

  void _accept([int? index]) {
    final token = _token;
    if (token == null || _options.isEmpty) return;
    final choice = _options[index ?? _highlighted];
    final value = token.complete(widget.controller.text, choice.name);
    widget.controller.value = value;
    widget.onChanged(value.text);
    widget.focusNode.requestFocus();
  }

  void _dismiss() {
    _dismissed = _token;
    _update();
  }

  Offset _fieldBottom() {
    final target = context.findRenderObject();
    return target is RenderBox && target.hasSize
        ? Offset(0, target.size.height + 4)
        : Offset.zero;
  }

  /// Where the list opens: just below the caret of the `{{` being typed,
  /// relative to the field. Falls back to the field's bottom-left corner.
  Offset _anchorOffset() {
    final target = context.findRenderObject();
    if (target is! RenderBox || !target.hasSize) return Offset.zero;
    final fallback = Offset(0, target.size.height + 4);
    final token = _token;
    EditableTextState? editable;
    void visit(Element e) {
      if (editable != null) return;
      if (e is StatefulElement && e.state is EditableTextState) {
        editable = e.state as EditableTextState;
        return;
      }
      e.visitChildElements(visit);
    }

    (context as Element).visitChildElements(visit);
    final render = editable?.renderEditable;
    if (token == null || render == null || !render.attached) return fallback;
    final caret = render.getLocalRectForCaret(
      TextPosition(offset: token.start),
    );
    final local = target.globalToLocal(render.localToGlobal(caret.bottomLeft));
    return Offset(
      local.dx.clamp(0, target.size.width).toDouble(),
      local.dy.clamp(0, target.size.height).toDouble() + 4,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bindings = <ShortcutActivator, VoidCallback>{
      if (_visible) ...{
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
        const SingleActivator(LogicalKeyboardKey.enter): _accept,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): _accept,
        const SingleActivator(LogicalKeyboardKey.tab): _accept,
        const SingleActivator(LogicalKeyboardKey.escape): _dismiss,
      },
    };
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (_) => _SuggestionList(
        link: _link,
        offset: _anchor ?? _fieldBottom(),
        options: _options,
        highlighted: _highlighted,
        onSelect: _accept,
        onHover: (i) => setState(() => _highlighted = i),
      ),
      child: CompositedTransformTarget(
        link: _link,
        child: CallbackShortcuts(bindings: bindings, child: widget.child),
      ),
    );
  }
}

class _SuggestionList extends StatelessWidget {
  const _SuggestionList({
    required this.link,
    required this.offset,
    required this.options,
    required this.highlighted,
    required this.onSelect,
    required this.onHover,
  });

  final LayerLink link;
  final Offset offset;
  final List<VariableSuggestion> options;
  final int highlighted;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onHover;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final mono = AppTheme.mono(context, size: 12);
    return CompositedTransformFollower(
      link: link,
      showWhenUnlinked: false,
      offset: offset,
      child: Align(
        alignment: Alignment.topLeft,
        // Taps inside count as "inside the field", so it keeps focus.
        child: TextFieldTapRegion(
          child: Material(
            color: colors.panelRaised,
            elevation: 8,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: colors.borderStrong),
            ),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 320, maxWidth: 460),
              child: IntrinsicWidth(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < options.length; i++)
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        onEnter: (_) => onHover(i),
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => onSelect(i),
                          child: Container(
                            color: i == highlighted ? colors.selection : null,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            child: Row(
                              children: [
                                Text(
                                  options[i].name,
                                  style: mono.copyWith(
                                    color: colors.variable,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    options[i].preview,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: mono.copyWith(
                                      color: colors.textSecondary,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  options[i].source,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: colors.textMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
