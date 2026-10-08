import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/platform_keys.dart';
import '../../auth/presentation/account_card.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../collections/presentation/collection_providers.dart';
import '../../collections/presentation/collection_tree_view.dart';
import '../../environments/presentation/environments_panel.dart';
import '../../history/presentation/history_panel.dart';
import '../../import_export/presentation/import_export_actions.dart';
import '../../sync/presentation/sync_dialog.dart';
import 'app_commands.dart';
import 'shell_state.dart';
import 'workspace_actions.dart';

class ActivityRail extends ConsumerWidget {
  const ActivityRail({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final shell = ref.watch(shellProvider);
    final session = ref.watch(authSessionProvider).value;

    Widget item(
      ShellSection s,
      IconData icon,
      IconData activeIcon,
      String label,
    ) {
      final selected =
          shell.section == s &&
          (s == ShellSection.settings || shell.sidebarVisible);
      return Tooltip(
        message: label,
        preferBelow: false,
        child: InkWell(
          onTap: () => ref.read(shellProvider.notifier).select(s),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: 40,
            height: 40,
            margin: const EdgeInsets.symmetric(vertical: 3),
            decoration: BoxDecoration(
              color: selected ? colors.selection : null,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              selected ? activeIcon : icon,
              size: 20,
              color: selected ? colors.accent : colors.textSecondary,
            ),
          ),
        ),
      );
    }

    return Container(
      width: 52,
      decoration: BoxDecoration(
        color: colors.canvas,
        border: Border(right: BorderSide(color: colors.border)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 10),
          const _Logo(),
          const SizedBox(height: 14),
          item(
            ShellSection.collections,
            Icons.folder_copy_outlined,
            Icons.folder_copy,
            'Collections',
          ),
          item(
            ShellSection.environments,
            Icons.layers_outlined,
            Icons.layers,
            'Environments',
          ),
          item(ShellSection.history, Icons.history, Icons.history, 'History'),
          const Spacer(),
          Tooltip(
            message: session == null ? 'Account' : session.account.email,
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => ref
                  .read(shellProvider.notifier)
                  .select(ShellSection.settings),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: session == null
                    ? Icon(
                        Icons.account_circle_outlined,
                        size: 22,
                        color: colors.textSecondary,
                      )
                    : Avatar(
                        initials: session.account.initials,
                        url: session.account.pictureUrl,
                        size: 26,
                      ),
              ),
            ),
          ),
          item(
            ShellSection.settings,
            Icons.settings_outlined,
            Icons.settings,
            'Settings (${PlatformKeys.combo(',')})',
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [colors.accent, colors.info],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(Icons.auto_awesome, size: 16, color: Colors.white),
    );
  }
}

class Sidebar extends ConsumerStatefulWidget {
  const Sidebar({super.key});

  @override
  ConsumerState<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends ConsumerState<Sidebar> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final section = ref.watch(shellProvider.select((s) => s.section));
    ref.listen(focusSearchRequestProvider, (_, _) {
      _searchFocus.requestFocus();
      _search.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _search.text.length,
      );
    });

    final (title, actions) = switch (section) {
      ShellSection.environments => (
        'Environments',
        <Widget>[
          IconButton(
            tooltip: 'Import environment',
            onPressed: () =>
                ImportExportActions(ref, context).importEnvironment(),
            icon: const Icon(Icons.file_download_outlined),
          ),
          IconButton(
            tooltip: 'New environment',
            onPressed: () => newEnvironmentCommand(context, ref),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      ShellSection.history => (
        'History',
        <Widget>[
          IconButton(
            tooltip: 'Clear history',
            onPressed: () => clearHistoryCommand(context, ref),
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      _ => (
        'Collections',
        <Widget>[
          MenuAnchor(
            builder: (context, c, _) => IconButton(
              tooltip: 'Import',
              onPressed: () => c.isOpen ? c.close() : c.open(),
              icon: const Icon(Icons.file_download_outlined),
            ),
            menuChildren: [
              MenuItemButton(
                onPressed: () =>
                    ImportExportActions(ref, context).importCollection(),
                child: const Text('Import collection file…'),
              ),
              MenuItemButton(
                onPressed: () => WorkspaceActions(ref, context).importCurl(),
                child: const Text('Import cURL…'),
              ),
              MenuItemButton(
                onPressed: () => showSyncDialog(context),
                child: const Text('Sync with GitHub…'),
              ),
            ],
          ),
          IconButton(
            tooltip: 'New collection (${PlatformKeys.combo('N', shift: true)})',
            onPressed: () => newCollectionCommand(context, ref),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    };

    return Container(
      color: colors.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 40,
            child: Padding(
              padding: const EdgeInsets.only(left: 14, right: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  ...actions,
                ],
              ),
            ),
          ),
          if (section != ShellSection.environments)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: SizedBox(
                height: 30,
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.escape): () {
                      _search.clear();
                      ref.read(sidebarSearchProvider.notifier).set('');
                      _searchFocus.unfocus();
                    },
                  },
                  child: TextField(
                    controller: _search,
                    focusNode: _searchFocus,
                    style: const TextStyle(fontSize: 12.5),
                    onChanged: ref.read(sidebarSearchProvider.notifier).set,
                    decoration: InputDecoration(
                      hintText: 'Search (${PlatformKeys.combo('K')})',
                      prefixIcon: Icon(
                        Icons.search,
                        size: 15,
                        color: colors.textMuted,
                      ),
                      prefixIconConstraints: const BoxConstraints(minWidth: 30),
                      contentPadding: const EdgeInsets.symmetric(vertical: 6),
                    ),
                  ),
                ),
              ),
            ),
          Expanded(
            child: switch (section) {
              ShellSection.environments => const EnvironmentsPanel(),
              ShellSection.history => const HistoryPanel(),
              _ => const CollectionTreeView(),
            },
          ),
        ],
      ),
    );
  }
}
