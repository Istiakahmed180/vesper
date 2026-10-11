import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/di/app_providers.dart';
import '../../../core/storage/app_database.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/dialogs.dart';
import '../../auth/presentation/account_card.dart';
import '../../collections/presentation/collection_providers.dart';
import '../../environments/presentation/environment_providers.dart';
import '../../github/presentation/github_card.dart';
import '../../history/presentation/history_panel.dart';
import '../../history/presentation/history_providers.dart';
import '../../import_export/presentation/import_export_actions.dart';
import '../../workspace/presentation/workspace_controller.dart';
import '../../workspaces/presentation/workspace_providers.dart';
import '../domain/app_settings.dart';
import 'settings_controller.dart';

enum _Section {
  general('General', Icons.tune),
  network('Network', Icons.lan_outlined),
  security('Security', Icons.shield_outlined),
  account('Accounts', Icons.person_outline),
  data('Data', Icons.storage_outlined);

  const _Section(this.label, this.icon);
  final String label;
  final IconData icon;
}

class SettingsView extends ConsumerStatefulWidget {
  const SettingsView({super.key});

  @override
  ConsumerState<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends ConsumerState<SettingsView> {
  _Section _section = _Section.general;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ColoredBox(
      color: colors.panel,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: 200,
            decoration: BoxDecoration(
              border: Border(right: BorderSide(color: colors.border)),
            ),
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                  child: Text(
                    'Settings',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                for (final s in _Section.values)
                  _NavItem(
                    icon: s.icon,
                    label: s.label,
                    selected: s == _section,
                    onTap: () => setState(() => _section = s),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(32, 24, 32, 40),
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: switch (_section) {
                    _Section.general => const _GeneralSettings(),
                    _Section.network => const _NetworkSettings(),
                    _Section.security => const _SecuritySettings(),
                    _Section.account => const _AccountSettings(),
                    _Section.data => const _DataSettings(),
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: selected ? colors.selection : null,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 16,
              color: selected ? colors.accent : colors.textSecondary,
            ),
            const SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: selected ? colors.textPrimary : colors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.title, required this.children, this.description});
  final String title;
  final String? description;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          if (description != null) ...[
            const SizedBox(height: 4),
            Text(
              description!,
              style: TextStyle(fontSize: 12, color: colors.textMuted),
            ),
          ],
          const SizedBox(height: 10),
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: colors.border),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) Divider(height: 1, color: colors.border),
                  children[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Setting extends StatelessWidget {
  const _Setting({required this.title, this.subtitle, required this.trailing});
  final String title;
  final String? subtitle;
  final Widget trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 13)),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    subtitle!,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: context.colors.textMuted,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        trailing,
      ],
    ),
  );
}

class _IntField extends StatefulWidget {
  const _IntField({
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1 << 30,
    this.width = 120,
  });
  final int value;
  final ValueChanged<int> onChanged;
  final int min;
  final int max;
  final double width;

  @override
  State<_IntField> createState() => _IntFieldState();
}

class _IntFieldState extends State<_IntField> {
  late final _c = TextEditingController(text: '${widget.value}');

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: widget.width,
    child: TextField(
      controller: _c,
      keyboardType: TextInputType.number,
      onChanged: (v) {
        final n = int.tryParse(v.trim());
        if (n != null) widget.onChanged(n.clamp(widget.min, widget.max));
      },
    ),
  );
}

class _TextSetting extends StatefulWidget {
  const _TextSetting({required this.value, required this.onChanged, this.hint});
  final String value;
  final ValueChanged<String> onChanged;
  final String? hint;

  @override
  State<_TextSetting> createState() => _TextSettingState();
}

class _TextSettingState extends State<_TextSetting> {
  late final _c = TextEditingController(text: widget.value);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 220,
    child: TextField(
      controller: _c,
      decoration: InputDecoration(hintText: widget.hint),
      onChanged: widget.onChanged,
    ),
  );
}

class _GeneralSettings extends ConsumerWidget {
  const _GeneralSettings();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final c = ref.read(settingsProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Group(
          title: 'Appearance',
          children: [
            _Setting(
              title: 'Theme',
              trailing: SegmentedButton<ThemeMode>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                  ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                  ButtonSegment(value: ThemeMode.system, label: Text('System')),
                ],
                selected: {s.themeMode},
                onSelectionChanged: (v) =>
                    c.update((x) => x.copyWith(themeMode: v.first)),
              ),
            ),
          ],
        ),
        _Group(
          title: 'Startup',
          children: [
            _Setting(
              title: 'On launch',
              subtitle: 'Unsaved drafts are never persisted to disk.',
              trailing: DropdownButton<StartupBehavior>(
                value: s.startupBehavior,
                items: const [
                  DropdownMenuItem(
                    value: StartupBehavior.restoreTabs,
                    child: Text('Reopen saved request tabs'),
                  ),
                  DropdownMenuItem(
                    value: StartupBehavior.blankTab,
                    child: Text('Start with a blank tab'),
                  ),
                ],
                onChanged: (v) =>
                    c.update((x) => x.copyWith(startupBehavior: v)),
              ),
            ),
          ],
        ),
        _Group(
          title: 'History',
          children: [
            _Setting(
              title: 'Record request history',
              trailing: Switch(
                value: s.historyEnabled,
                onChanged: (v) =>
                    c.update((x) => x.copyWith(historyEnabled: v)),
              ),
            ),
            _Setting(
              title: 'Keep history for (days)',
              subtitle: '0 keeps history until the entry limit is reached.',
              trailing: _IntField(
                value: s.historyRetentionDays,
                max: 3650,
                onChanged: (v) =>
                    c.update((x) => x.copyWith(historyRetentionDays: v)),
              ),
            ),
            _Setting(
              title: 'Maximum entries',
              trailing: _IntField(
                value: s.historyMaxEntries,
                min: 10,
                max: 100000,
                onChanged: (v) =>
                    c.update((x) => x.copyWith(historyMaxEntries: v)),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _NetworkSettings extends ConsumerWidget {
  const _NetworkSettings();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.watch(settingsProvider.select((s) => s.network));
    final c = ref.read(settingsProvider.notifier);
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Group(
          title: 'Requests',
          children: [
            _Setting(
              title: 'Request timeout (ms)',
              subtitle:
                  'Applies to connecting and receiving. Requests can override it.',
              trailing: _IntField(
                value: n.timeoutMs,
                min: 1000,
                max: 600000,
                onChanged: (v) =>
                    c.updateNetwork((x) => x.copyWith(timeoutMs: v)),
              ),
            ),
            _Setting(
              title: 'Follow redirects',
              trailing: Switch(
                value: n.followRedirects,
                onChanged: (v) =>
                    c.updateNetwork((x) => x.copyWith(followRedirects: v)),
              ),
            ),
            _Setting(
              title: 'Maximum redirects',
              trailing: _IntField(
                value: n.maxRedirects,
                max: 50,
                width: 80,
                onChanged: (v) =>
                    c.updateNetwork((x) => x.copyWith(maxRedirects: v)),
              ),
            ),
            _Setting(
              title: 'Send cookies automatically',
              subtitle: 'Cookies are kept in memory for this session only.',
              trailing: Switch(
                value: n.sendCookies,
                onChanged: (v) =>
                    c.updateNetwork((x) => x.copyWith(sendCookies: v)),
              ),
            ),
          ],
        ),
        _Group(
          title: 'SSL',
          children: [
            _Setting(
              title: 'Verify SSL certificates',
              subtitle: n.verifySsl
                  ? 'Recommended. Requests to servers with invalid certificates fail.'
                  : 'Disabled: connections are vulnerable to interception. Use only for local development.',
              trailing: Switch(
                value: n.verifySsl,
                onChanged: (v) async {
                  if (!v &&
                      !await confirmDialog(
                        context,
                        title: 'Disable SSL verification?',
                        message:
                            'Vesper will accept any certificate, including forged ones. Only do this for local development servers.',
                        confirmLabel: 'Disable',
                      )) {
                    return;
                  }
                  c.updateNetwork((x) => x.copyWith(verifySsl: v));
                },
              ),
            ),
            if (!n.verifySsl)
              Container(
                color: colors.warning.withValues(alpha: 0.1),
                padding: const EdgeInsets.all(10),
                child: Text(
                  'SSL verification is off for all requests.',
                  style: TextStyle(fontSize: 12, color: colors.warning),
                ),
              ),
          ],
        ),
        _Group(
          title: 'Proxy',
          description:
              'HTTP proxy for API requests (HTTPS is tunnelled with CONNECT). Proxy authentication and PAC files are not supported yet.',
          children: [
            _Setting(
              title: 'Use a proxy',
              trailing: Switch(
                value: n.proxy.enabled,
                onChanged: (v) => c.updateNetwork(
                  (x) => x.copyWith(proxy: x.proxy.copyWith(enabled: v)),
                ),
              ),
            ),
            _Setting(
              title: 'Host',
              trailing: _TextSetting(
                value: n.proxy.host,
                hint: 'proxy.example.com',
                onChanged: (v) => c.updateNetwork(
                  (x) => x.copyWith(proxy: x.proxy.copyWith(host: v.trim())),
                ),
              ),
            ),
            _Setting(
              title: 'Port',
              trailing: _IntField(
                value: n.proxy.port,
                min: 1,
                max: 65535,
                width: 90,
                onChanged: (v) => c.updateNetwork(
                  (x) => x.copyWith(proxy: x.proxy.copyWith(port: v)),
                ),
              ),
            ),
            _Setting(
              title: 'Bypass for hosts',
              subtitle: 'Comma separated.',
              trailing: _TextSetting(
                value: n.proxy.bypass,
                onChanged: (v) => c.updateNetwork(
                  (x) => x.copyWith(proxy: x.proxy.copyWith(bypass: v)),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _SecuritySettings extends ConsumerWidget {
  const _SecuritySettings();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final store = Platform.isMacOS
        ? 'macOS Keychain'
        : 'Windows Credential Manager (DPAPI)';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Group(
          title: 'Credential storage',
          children: [
            _Setting(
              title: 'Secrets are stored in the $store',
              subtitle:
                  'Auth tokens, passwords, API keys, secret variables and account sessions never touch the SQLite database.',
              trailing: Icon(
                Icons.verified_user_outlined,
                color: colors.success,
              ),
            ),
            _Setting(
              title: 'Remove all stored secrets',
              subtitle:
                  'Deletes every credential Vesper saved in the system store. Saved requests keep their non-secret settings.',
              trailing: OutlinedButton(
                onPressed: () async {
                  final ok = await confirmDialog(
                    context,
                    title: 'Remove stored secrets',
                    message:
                        'Delete all tokens, passwords and secret variables from the system store? You will be signed out of Google and GitHub.',
                    confirmLabel: 'Remove secrets',
                  );
                  if (!ok || !context.mounted) return;
                  await guarded(context, () async {
                    await ref.read(vaultProvider).clear();
                    ref.invalidate(environmentsProvider);
                  }, success: 'Secrets removed');
                },
                child: const Text('Remove…'),
              ),
            ),
          ],
        ),
        _Group(
          title: 'Diagnostics',
          children: [
            _Setting(
              title: 'Application logs',
              subtitle:
                  'Logs never contain tokens, passwords or query string values.',
              trailing: OutlinedButton(
                onPressed: () async {
                  final dir = await getApplicationSupportDirectory();
                  await launchUrl(
                    Uri.directory('${dir.path}${Platform.pathSeparator}logs'),
                  );
                },
                child: const Text('Open folder'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _AccountSettings extends StatelessWidget {
  const _AccountSettings();

  @override
  Widget build(BuildContext context) => const Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _Group(title: 'Vesper account', children: [AccountCard()]),
      _Group(
        title: 'GitHub',
        description:
            'Store collections in a GitHub repository. Nothing is pushed without your confirmation.',
        children: [GitHubCard()],
      ),
    ],
  );
}

class _DataSettings extends ConsumerWidget {
  const _DataSettings();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final io = ImportExportActions(ref, context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Group(
          title: 'Import',
          children: [
            _Setting(
              title: 'Import a collection',
              subtitle:
                  'Vesper or Postman Collection v2.x JSON. Scripts are never executed.',
              trailing: OutlinedButton(
                onPressed: io.importCollection,
                child: const Text('Import…'),
              ),
            ),
            _Setting(
              title: 'Import an environment',
              subtitle: 'Vesper or Postman environment JSON.',
              trailing: OutlinedButton(
                onPressed: io.importEnvironment,
                child: const Text('Import…'),
              ),
            ),
          ],
        ),
        _Group(
          title: 'Export',
          description:
              'Export collections and environments from their context menu in the sidebar.',
          children: [
            _Setting(
              title: 'Format',
              subtitle:
                  'Versioned Vesper JSON (format v1). Secrets are excluded unless you opt in.',
              trailing: Icon(Icons.data_object, color: colors.textSecondary),
            ),
          ],
        ),
        _Group(
          title: 'Danger zone',
          children: [
            _Setting(
              title: 'Clear history',
              trailing: OutlinedButton(
                onPressed: () => clearHistoryCommand(context, ref),
                child: const Text('Clear…'),
              ),
            ),
            _Setting(
              title: 'Clear local database',
              subtitle:
                  'Deletes all workspaces, collections, environments, history, settings and stored secrets on this computer.',
              trailing: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: colors.danger),
                onPressed: () async {
                  final ok = await confirmDialog(
                    context,
                    title: 'Delete all local data?',
                    message:
                        'All workspaces, collections, environments, history, settings and secrets stored by Vesper on this computer will be permanently deleted. Export anything you want to keep first.',
                    confirmLabel: 'Delete everything',
                  );
                  if (!ok || !context.mounted) return;
                  await guarded(context, () async {
                    await ref
                        .read(activeWorkspaceIdProvider.notifier)
                        .select(defaultWorkspaceId);
                    await ref.read(databaseProvider).wipe();
                    await ref.read(vaultProvider).clear();
                    ref.read(cookieStoreProvider).clear();
                    ref.invalidate(environmentRepositoryProvider);
                    ref.invalidate(collectionTreesProvider);
                    ref.invalidate(historyProvider);
                    ref
                        .read(settingsProvider.notifier)
                        .update((_) => const AppSettings());
                    ref.invalidate(workspaceProvider);
                  }, success: 'Local data deleted');
                },
                child: const Text('Delete…'),
              ),
            ),
          ],
        ),
        Text(
          '${AppConstants.appName} ${AppConstants.appVersion}',
          style: TextStyle(fontSize: 11.5, color: colors.textMuted),
        ),
      ],
    );
  }
}
