import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/di/app_providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/dialogs.dart';
import '../../api_client/presentation/request/request_editor.dart';
import '../../environments/presentation/environment_editor.dart';
import '../../environments/presentation/environment_providers.dart';
import '../../github/presentation/github_providers.dart';
import '../../settings/presentation/settings_view.dart';
import '../../workspaces/presentation/workspace_providers.dart';
import '../domain/workspace_models.dart';
import 'app_commands.dart';
import 'shell_state.dart';
import 'sidebar.dart';
import 'tab_strip.dart';
import 'workspace_controller.dart';

/// Whether the app runs inside a real desktop window managed by
/// window_manager (false in widget tests).
final windowManagedProvider = Provider<bool>((ref) => false);

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> with WindowListener {
  late final bool _windowManaged;
  late final AppLifecycleListener _lifecycle;
  Future<bool>? _pendingExit;
  bool _exitConfirmed = false;

  @override
  void initState() {
    super.initState();
    _windowManaged = ref.read(windowManagedProvider);
    // Quit from the menu, Dock or system arrives as an exit request.
    _lifecycle = AppLifecycleListener(onExitRequested: _onExitRequested);
    if (_windowManaged) {
      windowManager.addListener(this);
      unawaited(windowManager.setPreventClose(true));
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    if (_windowManaged) windowManager.removeListener(this);
    super.dispose();
  }

  Future<AppExitResponse> _onExitRequested() async {
    if (!await _confirmExit()) return AppExitResponse.cancel;
    // macOS occasionally drops the termination after an asynchronous exit
    // approval (seen with Apple Event quits). Re-request it; if the app is
    // already exiting this never runs.
    if (_windowManaged) {
      Timer(
        const Duration(seconds: 2),
        () => unawaited(windowManager.destroy()),
      );
    }
    return AppExitResponse.exit;
  }

  @override
  Future<void> onWindowClose() async {
    if (await _confirmExit()) await windowManager.destroy();
  }

  /// Asks before discarding unsaved tabs, then flushes the log and closes the
  /// database. Concurrent close/quit requests share one prompt.
  Future<bool> _confirmExit() {
    if (_exitConfirmed) return Future.value(true);
    return _pendingExit ??= () async {
      try {
        final dirty = ref
            .read(workspaceProvider)
            .tabs
            .whereType<RequestTab>()
            .where((t) => t.isDirty)
            .length;
        if (dirty > 0 && mounted) {
          final ok = await confirmDialog(
            context,
            title: 'Quit ${AppConstants.appName}?',
            message: '$dirty tab(s) have unsaved changes that will be lost.',
            confirmLabel: 'Quit',
          );
          if (!ok) return false;
        }
        _exitConfirmed = true;
        final logger = ref.read(loggerProvider)..info('Application closing');
        await logger.close();
        await ref.read(databaseProvider).close();
        return true;
      } finally {
        _pendingExit = null;
      }
    }();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final shell = ref.watch(shellProvider);
    final runner = CommandRunner(ref, context);
    final nativeMenus = ref.watch(nativeMenusProvider);

    Widget content = Scaffold(
      backgroundColor: colors.canvas,
      body: Column(
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const ActivityRail(),
                if (shell.sidebarVisible &&
                    shell.section != ShellSection.settings) ...[
                  SizedBox(width: shell.sidebarWidth, child: const Sidebar()),
                  _SidebarResizer(width: shell.sidebarWidth),
                ],
                Expanded(
                  child: shell.section == ShellSection.settings
                      ? const SettingsView()
                      : const _MainArea(),
                ),
              ],
            ),
          ),
          const _StatusBar(),
        ],
      ),
    );

    // Keyboard shortcuts: handled by the native menu bar on macOS, otherwise here.
    if (!nativeMenus) {
      content = CallbackShortcuts(
        bindings: {
          for (final c in AppCommand.values) c.activator: () => runner.run(c),
        },
        child: Focus(autofocus: true, child: content),
      );
    } else {
      content = PlatformMenuBar(
        menus: _menus(runner),
        child: Focus(autofocus: true, child: content),
      );
    }
    return content;
  }

  List<PlatformMenuItem> _menus(CommandRunner runner) {
    PlatformMenuItem cmd(AppCommand c) => PlatformMenuItem(
      label: c.label,
      shortcut: c.activator,
      onSelected: () => runner.run(c),
    );
    return [
      PlatformMenu(
        label: AppConstants.appName,
        menus: [
          PlatformMenuItemGroup(
            members: [
              if (PlatformProvidedMenuItem.hasMenu(
                PlatformProvidedMenuItemType.about,
              ))
                const PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.about,
                ),
            ],
          ),
          PlatformMenuItemGroup(members: [cmd(AppCommand.settings)]),
          const PlatformMenuItemGroup(
            members: [
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.servicesSubmenu,
              ),
            ],
          ),
          const PlatformMenuItemGroup(
            members: [
              PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.hideOtherApplications,
              ),
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.showAllApplications,
              ),
            ],
          ),
          const PlatformMenuItemGroup(
            members: [
              PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
            ],
          ),
        ],
      ),
      PlatformMenu(
        label: 'File',
        menus: [
          PlatformMenuItemGroup(
            members: [
              cmd(AppCommand.newTab),
              cmd(AppCommand.newCollection),
              cmd(AppCommand.newEnvironment),
            ],
          ),
          PlatformMenuItemGroup(
            members: [cmd(AppCommand.save), cmd(AppCommand.saveAs)],
          ),
          PlatformMenuItemGroup(
            members: [
              cmd(AppCommand.importCollection),
              cmd(AppCommand.importCurl),
            ],
          ),
          PlatformMenuItemGroup(
            members: [cmd(AppCommand.duplicateTab), cmd(AppCommand.closeTab)],
          ),
        ],
      ),
      PlatformMenu(
        label: 'Request',
        menus: [
          PlatformMenuItemGroup(
            members: [cmd(AppCommand.send), cmd(AppCommand.cancel)],
          ),
          PlatformMenuItemGroup(
            members: [cmd(AppCommand.focusUrl), cmd(AppCommand.copyCurl)],
          ),
        ],
      ),
      PlatformMenu(
        label: 'View',
        menus: [
          PlatformMenuItemGroup(
            members: [cmd(AppCommand.toggleSidebar), cmd(AppCommand.search)],
          ),
          PlatformMenuItemGroup(
            members: [cmd(AppCommand.nextTab), cmd(AppCommand.previousTab)],
          ),
          if (PlatformProvidedMenuItem.hasMenu(
            PlatformProvidedMenuItemType.toggleFullScreen,
          ))
            const PlatformMenuItemGroup(
              members: [
                PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.toggleFullScreen,
                ),
              ],
            ),
        ],
      ),
      const PlatformMenu(
        label: 'Window',
        menus: [
          PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.minimizeWindow,
          ),
          PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.zoomWindow,
          ),
          PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.arrangeWindowsInFront,
          ),
        ],
      ),
    ];
  }
}

class _SidebarResizer extends ConsumerWidget {
  const _SidebarResizer({required this.width});
  final double width;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) =>
            ref.read(shellProvider.notifier).resize(width + d.delta.dx),
        child: SizedBox(
          width: 5,
          child: Center(child: Container(width: 1, color: colors.border)),
        ),
      ),
    );
  }
}

class _MainArea extends ConsumerWidget {
  const _MainArea();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(
      workspaceProvider.select((s) {
        final t = s.activeTab;
        return switch (t) {
          RequestTab() => ('request', t.id),
          EnvironmentTab() => ('env:${t.environmentId}', t.id),
          null => ('none', ''),
        };
      }),
    );
    final (kind, tabId) = active;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const TabStrip(),
        Expanded(
          child: switch (kind) {
            'request' => RequestWorkspace(key: ValueKey(tabId), tabId: tabId),
            'none' => const SizedBox.shrink(),
            _ => EnvironmentEditor(
              key: ValueKey(tabId),
              environmentId: kind.substring(4),
            ),
          },
        ),
      ],
    );
  }
}

class _StatusBar extends ConsumerWidget {
  const _StatusBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final env = ref.watch(activeEnvironmentProvider);
    final workspace = ref.watch(activeWorkspaceProvider);
    final github = ref.watch(githubSessionProvider).value;
    final style = TextStyle(fontSize: 11.5, color: colors.textMuted);
    Widget item(IconData icon, String text, {Color? color}) => Padding(
      padding: const EdgeInsets.only(right: 16),
      child: Row(
        children: [
          Icon(icon, size: 12, color: color ?? colors.textMuted),
          const SizedBox(width: 5),
          Text(text, style: style),
        ],
      ),
    );
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: colors.canvas,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          item(Icons.workspaces_outline, workspace?.name ?? 'Workspace'),
          item(
            Icons.layers_outlined,
            env == null ? 'No environment' : env.name,
            color: env == null ? null : colors.success,
          ),
          if (github != null)
            item(Icons.hub_outlined, '@${github.account.login}'),
          const Spacer(),
          Text(
            '${AppConstants.appName} ${AppConstants.appVersion} · ${Platform.operatingSystem}',
            style: style,
          ),
        ],
      ),
    );
  }
}
