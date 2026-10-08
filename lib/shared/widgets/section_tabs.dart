import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

class SectionTab {
  const SectionTab(this.label, {this.badge, this.dot = false});
  final String label;
  final String? badge;
  final bool dot;
}

/// Compact underline tabs used for request / response sections.
class SectionTabs extends StatelessWidget {
  const SectionTabs({
    super.key,
    required this.tabs,
    required this.selected,
    required this.onSelected,
    this.trailing,
  });

  final List<SectionTab> tabs;
  final int selected;
  final ValueChanged<int> onSelected;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      height: 36,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < tabs.length; i++)
                    _TabButton(
                      tab: tabs[i],
                      selected: i == selected,
                      onTap: () => onSelected(i),
                    ),
                ],
              ),
            ),
          ),
          if (trailing != null)
            Flexible(
              child: Align(
                alignment: Alignment.centerRight,
                child: FittedBox(fit: BoxFit.scaleDown, child: trailing),
              ),
            ),
        ],
      ),
    );
  }
}

class _TabButton extends StatefulWidget {
  const _TabButton({
    required this.tab,
    required this.selected,
    required this.onTap,
  });
  final SectionTab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_TabButton> createState() => _TabButtonState();
}

class _TabButtonState extends State<_TabButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final color = widget.selected
        ? colors.textPrimary
        : (_hover ? colors.textPrimary : colors.textSecondary);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: widget.selected ? colors.accent : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          alignment: Alignment.center,
          child: Row(
            children: [
              Text(
                widget.tab.label,
                style: TextStyle(
                  fontSize: 12.5,
                  color: color,
                  fontWeight: widget.selected
                      ? FontWeight.w600
                      : FontWeight.w500,
                ),
              ),
              if (widget.tab.badge != null) ...[
                const SizedBox(width: 5),
                Text(
                  widget.tab.badge!,
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.success,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              if (widget.tab.dot) ...[
                const SizedBox(width: 5),
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: colors.success,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Small segmented control (e.g. Pretty / Raw / Preview).
class Segmented<T> extends StatelessWidget {
  const Segmented({
    super.key,
    required this.values,
    required this.selected,
    required this.label,
    required this.onChanged,
  });

  final List<T> values;
  final T selected;
  final String Function(T) label;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      height: 26,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: colors.canvas,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final v in values)
            GestureDetector(
              onTap: () => onChanged(v),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: v == selected
                        ? colors.panelRaised
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    label(v),
                    style: TextStyle(
                      fontSize: 12,
                      color: v == selected
                          ? colors.textPrimary
                          : colors.textSecondary,
                      fontWeight: v == selected
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 34, color: colors.textMuted),
            const SizedBox(height: 12),
            Text(
              title,
              style: Theme.of(context).textTheme.titleSmall,
              textAlign: TextAlign.center,
            ),
            if (message != null) ...[
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 12.5,
                    height: 1.45,
                  ),
                ),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 14), action!],
          ],
        ),
      ),
    );
  }
}

/// Keyboard shortcut hint like "⌘ ↵".
class KeyHint extends StatelessWidget {
  const KeyHint(this.keys, {super.key});
  final String keys;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colors.panelRaised,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: colors.border),
      ),
      child: Text(
        keys,
        style: TextStyle(fontSize: 11, color: colors.textSecondary),
      ),
    );
  }
}
