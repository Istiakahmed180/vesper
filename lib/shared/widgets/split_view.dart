import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// Two panes separated by a draggable divider. [initialFraction] is the size of
/// the first pane relative to the available space.
class SplitView extends StatefulWidget {
  const SplitView({
    super.key,
    required this.first,
    required this.second,
    this.axis = Axis.vertical,
    this.initialFraction = 0.5,
    this.minFirst = 120,
    this.minSecond = 120,
    this.onChanged,
  });

  final Widget first;
  final Widget second;
  final Axis axis;
  final double initialFraction;
  final double minFirst;
  final double minSecond;
  final ValueChanged<double>? onChanged;

  @override
  State<SplitView> createState() => _SplitViewState();
}

class _SplitViewState extends State<SplitView> {
  late double _fraction = widget.initialFraction;
  bool _hover = false;
  bool _dragging = false;

  static const _handle = 6.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final vertical = widget.axis == Axis.vertical;
      final total =
          (vertical ? constraints.maxHeight : constraints.maxWidth) - _handle;
      final minF = widget.minFirst.clamp(0, total).toDouble();
      final maxF = (total - widget.minSecond).clamp(minF, total).toDouble();
      final firstSize = (total * _fraction).clamp(minF, maxF);
      final colors = context.colors;

      final divider = MouseRegion(
        cursor: vertical
            ? SystemMouseCursors.resizeRow
            : SystemMouseCursors.resizeColumn,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => setState(() => _dragging = true),
          onPanEnd: (_) {
            setState(() => _dragging = false);
            widget.onChanged?.call(_fraction);
          },
          onPanUpdate: (d) {
            final delta = vertical ? d.delta.dy : d.delta.dx;
            setState(() {
              _fraction = ((firstSize + delta) / total).clamp(
                minF / total,
                maxF / total,
              );
            });
          },
          onDoubleTap: () => setState(() => _fraction = widget.initialFraction),
          child: SizedBox(
            width: vertical ? double.infinity : _handle,
            height: vertical ? _handle : double.infinity,
            child: Center(
              child: Container(
                width: vertical
                    ? double.infinity
                    : (_hover || _dragging ? 2 : 1),
                height: vertical
                    ? (_hover || _dragging ? 2 : 1)
                    : double.infinity,
                color: _hover || _dragging ? colors.accent : colors.border,
              ),
            ),
          ),
        ),
      );

      final children = [
        SizedBox(
          width: vertical ? null : firstSize,
          height: vertical ? firstSize : null,
          child: widget.first,
        ),
        divider,
        Expanded(child: widget.second),
      ];
      return vertical ? Column(children: children) : Row(children: children);
    },
  );
}
