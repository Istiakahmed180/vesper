import 'package:flutter/material.dart';

/// Table-header checkbox that switches every row on or off. Shows a dash
/// when only some rows are enabled.
class AllRowsCheckbox extends StatelessWidget {
  const AllRowsCheckbox({
    super.key,
    required this.total,
    required this.enabled,
    required this.onChanged,
  });

  final int total;
  final int enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final value = total == 0 || enabled == 0
        ? false
        : enabled == total
        ? true
        : null;
    return Tooltip(
      message: value == true ? 'Disable all' : 'Enable all',
      child: Checkbox(
        key: const ValueKey('all-rows-checkbox'),
        tristate: true,
        value: value,
        // A tri-state checkbox cycles; map it to "all on" unless all are on.
        onChanged: total == 0 ? null : (_) => onChanged(value != true),
      ),
    );
  }
}
