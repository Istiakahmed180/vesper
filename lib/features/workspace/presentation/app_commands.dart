import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/platform_keys.dart';
import '../../api_client/presentation/request/url_bar.dart';
import '../../collections/presentation/collection_tree_view.dart';
import '../../environments/presentation/environments_panel.dart';
import '../../import_export/presentation/import_export_actions.dart';
import 'shell_state.dart';
import 'workspace_actions.dart';
import 'workspace_controller.dart';

enum AppCommand {
  newTab('New Tab', 'T'),
  newCollection('New Collection…', 'N', shift: true),
  newEnvironment('New Environment…', 'E', shift: true),
  closeTab('Close Tab', 'W'),
  duplicateTab('Duplicate Tab', 'D'),
  save('Save', 'S'),
  saveAs('Save As…', 'S', shift: true),
  send('Send Request', 'Enter'),
  cancel('Cancel Request', 'Period'),
  focusUrl('Focus URL', 'L'),
  search('Search', 'K'),
  nextTab('Next Tab', 'BracketRight', shift: true),
  previousTab('Previous Tab', 'BracketLeft', shift: true),
  importCollection('Import Collection…', 'O'),
  importCurl('Import cURL…', 'I'),
  copyCurl('Copy as cURL', 'C', shift: true),
  toggleSidebar('Toggle Sidebar', 'B'),
  settings('Settings…', 'Comma');

  const AppCommand(this.label, this.key, {this.shift = false});

  final String label;
  final String key;
  final bool shift;

  LogicalKeyboardKey get logicalKey => switch (key) {
    'Enter' => LogicalKeyboardKey.enter,
    'Period' => LogicalKeyboardKey.period,
    'Comma' => LogicalKeyboardKey.comma,
    'BracketRight' => LogicalKeyboardKey.bracketRight,
    'BracketLeft' => LogicalKeyboardKey.bracketLeft,
    final k => LogicalKeyboardKey(k.toLowerCase().codeUnitAt(0)),
  };

  /// Cmd on macOS, Ctrl on Windows.
  SingleActivator get activator => SingleActivator(
    logicalKey,
    meta: PlatformKeys.isMac,
    control: !PlatformKeys.isMac,
    shift: shift,
  );
}

/// Incremented to focus the sidebar search box.
final focusSearchRequestProvider = NotifierProvider<FocusSearchRequest, int>(
  FocusSearchRequest.new,
);

class FocusSearchRequest extends Notifier<int> {
  @override
  int build() => 0;
  void request() => state++;
}

/// Executes [AppCommand]s. Shared by keyboard shortcuts and the macOS menu.
class CommandRunner {
  const CommandRunner(this.ref, this.context);

  final WidgetRef ref;
  final BuildContext context;

  void run(AppCommand command) {
    final actions = WorkspaceActions(ref, context);
    final shell = ref.read(shellProvider.notifier);
    switch (command) {
      case AppCommand.newTab:
        shell.leaveSettings();
        actions.newTab();
      case AppCommand.newCollection:
        unawaited(newCollectionCommand(context, ref));
      case AppCommand.newEnvironment:
        unawaited(newEnvironmentCommand(context, ref));
      case AppCommand.closeTab:
        unawaited(actions.closeTab());
      case AppCommand.duplicateTab:
        actions.duplicateTab();
      case AppCommand.save:
        unawaited(actions.save());
      case AppCommand.saveAs:
        unawaited(actions.save(null, true));
      case AppCommand.send:
        shell.leaveSettings();
        unawaited(actions.send());
      case AppCommand.cancel:
        actions.cancel();
      case AppCommand.focusUrl:
        shell.leaveSettings();
        ref.read(focusUrlRequestProvider.notifier).request();
      case AppCommand.search:
        if (ref.read(shellProvider).section == ShellSection.settings ||
            ref.read(shellProvider).section == ShellSection.environments) {
          shell.showSection(ShellSection.collections);
        } else {
          shell.showSection(ref.read(shellProvider).section);
        }
        ref.read(focusSearchRequestProvider.notifier).request();
      case AppCommand.nextTab:
        ref.read(workspaceProvider.notifier).cycleTab(1);
      case AppCommand.previousTab:
        ref.read(workspaceProvider.notifier).cycleTab(-1);
      case AppCommand.importCollection:
        unawaited(ImportExportActions(ref, context).importCollection());
      case AppCommand.importCurl:
        shell.leaveSettings();
        unawaited(actions.importCurl());
      case AppCommand.copyCurl:
        unawaited(actions.copyAsCurl());
      case AppCommand.toggleSidebar:
        shell.toggleSidebar();
      case AppCommand.settings:
        shell.select(ShellSection.settings);
    }
  }
}
