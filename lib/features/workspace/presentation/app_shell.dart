import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/di/app_providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/shutdown.dart';
import '../../../shared/widgets/dialogs.dart';
import '../../api_client/presentation/request/request_editor.dart';
import '../../cloud_sync/presentation/cloud_sync_controller.dart';
import '../../cloud_sync/presentation/cloud_sync_widgets.dart';
import '../../collections/presentation/collection_editor.dart';
import '../../environments/presentation/environment_editor.dart';
import '../../environments/presentation/environment_providers.dart';
import '../../github/presentation/github_providers.dart';
import '../../settings/presentation/settings_view.dart';
import '../../updates/presentation/update_controller.dart';
import '../../updates/presentation/update_widgets.dart';
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
  Future<void>? _cleanup;
  bool _exitConfirmed = false;
  final _shellFocus = FocusNode(debugLabel: 'shell');

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_keepFocusInShell);
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
    FocusManager.instance.removeListener(_keepFocusInShell);
    _shellFocus.dispose();
    _lifecycle.dispose();
    if (_windowManaged) windowManager.removeListener(this);
    super.dispose();
  }

  /// Shortcuts only see key events while focus is inside the shell. When the
  /// focused field is clicked out of or removed, focus falls back to an
  /// enclosing scope; pull it back so e.g. Cmd/Ctrl+Enter keeps working.
  /// Dialogs have their own scope and are left alone.
  void _keepFocusInShell() {
    final primary = FocusManager.instance.primaryFocus;
    if (primary is FocusScopeNode &&
        _shellFocus.context != null &&
        _shellFocus.ancestors.contains(primary)) {
      _shellFocus.requestFocus();
    }
  }

  Future<AppExitResponse> _onExitRequested() async {
    if (!await _confirmExit()) return AppExitResponse.cancel;
    await _cleanUp();
    // macOS occasionally drops the termination after an asynchronous exit
    // approval (seen with Apple Event quits). Re-request it; if the app is
    // already exiting this never runs.
    if (_windowManaged) {
      Timer(const Duration(seconds: 2), () => unawaited(_forceQuit()));
    }
    return AppExitResponse.exit;
  }

  @override
  Future<void> onWindowClose() async {
    if (!await _confirmExit()) return;
    // Hide right away so closing feels instant, even while cleaning up.
    try {
      await windowManager.hide();
    } catch (_) {}
    await _cleanUp();
    await _forceQuit();
  }

  /// Ends the process. `destroy` stops the message loop; if the process is
  /// still around shortly after (seen on Windows), exit hard: the log and
  /// database are already closed.
  Future<void> _forceQuit() async {
    Timer(const Duration(milliseconds: 1500), () => exit(0));
    try {
      await windowManager.destroy();
    } catch (_) {
      exit(0);
    }
  }

  /// Asks before discarding unsaved tabs. Concurrent close/quit requests
  /// share one prompt; once confirmed, later requests go straight through.
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
        return true;
      } finally {
        _pendingExit = null;
      }
    }();
  }

  /// Flushes the log and closes the database, at most a few seconds.
  Future<void> _cleanUp() => _cleanup ??= () async {
    final logger = ref.read(loggerProvider)..info('Application closing');
    final db = ref.read(databaseProvider);
    await runShutdownSteps([logger.close, db.close]);
  }();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final shell = ref.watch(shellProvider);
    ref.listen(cloudSyncProvider.select((s) => s.phase), (previous, phase) {
      if (phase == CloudSyncPhase.accountChanged &&
          previous != CloudSyncPhase.accountChanged) {
        unawaited(
          showAccountChangedDialog(
            context,
            ref.read(cloudSyncProvider).previousAccount ?? 'another account',
          ),
        );
      }
    });
    ref.listen(joinedWorkspacesProvider, (_, names) {
      if (names.isEmpty) return;
      showToast(
        context,
        names.length == 1
            ? 'You were added to the "${names.single}" workspace.'
            : 'You were added to ${names.length} workspaces: ${names.join(', ')}.',
      );
      ref.read(joinedWorkspacesProvider.notifier).clear();
    });
    // Starts the background update checks.
    ref.watch(updateProvider.select((_) => null));
    final runner = CommandRunner(ref, context);
    final nativeMenus = ref.watch(nativeMenusProvider);

    Widget content = Scaffold(
      backgroundColor: colors.canvas,
      body: Column(
        children: [
          const UpdateBanner(),
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
        child: Focus(focusNode: _shellFocus, autofocus: true, child: content),
      );
    } else {
      content = PlatformMenuBar(
        menus: _menus(runner),
        child: Focus(focusNode: _shellFocus, autofocus: true, child: content),
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
          CollectionTab() => ('collection:${t.collectionId}', t.id),
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
            _ when kind.startsWith('collection:') => CollectionEditor(
              key: ValueKey(tabId),
              tabId: tabId,
            ),
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
          const CloudSyncStatus(),
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
