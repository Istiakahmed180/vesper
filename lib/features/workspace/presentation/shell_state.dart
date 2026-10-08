import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum ShellSection { collections, environments, history, settings }

@immutable
class ShellState {
  const ShellState({
    this.section = ShellSection.collections,
    this.sidebarVisible = true,
    this.sidebarWidth = 290,
  });

  final ShellSection section;
  final bool sidebarVisible;
  final double sidebarWidth;

  ShellState copyWith({
    ShellSection? section,
    bool? sidebarVisible,
    double? sidebarWidth,
  }) => ShellState(
    section: section ?? this.section,
    sidebarVisible: sidebarVisible ?? this.sidebarVisible,
    sidebarWidth: sidebarWidth ?? this.sidebarWidth,
  );
}

final shellProvider = NotifierProvider<ShellController, ShellState>(
  ShellController.new,
);

class ShellController extends Notifier<ShellState> {
  @override
  ShellState build() => const ShellState();

  /// Selecting the current sidebar section again collapses the sidebar.
  void select(ShellSection section) {
    if (section == ShellSection.settings) {
      state = state.copyWith(
        section: state.section == ShellSection.settings
            ? ShellSection.collections
            : section,
      );
      return;
    }
    if (state.section == section && state.sidebarVisible) {
      state = state.copyWith(sidebarVisible: false);
    } else {
      state = state.copyWith(section: section, sidebarVisible: true);
    }
  }

  void showSection(ShellSection section) =>
      state = state.copyWith(section: section, sidebarVisible: true);

  void toggleSidebar() =>
      state = state.copyWith(sidebarVisible: !state.sidebarVisible);

  void resize(double width) =>
      state = state.copyWith(sidebarWidth: width.clamp(220, 520));

  void leaveSettings() {
    if (state.section == ShellSection.settings) {
      state = state.copyWith(section: ShellSection.collections);
    }
  }
}
