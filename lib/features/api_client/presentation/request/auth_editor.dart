import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/di/app_providers.dart';
import '../../../../core/errors/app_failure.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../shared/widgets/dialogs.dart';
import '../../../../shared/widgets/secret_field.dart';
import '../../../../shared/widgets/variable_field.dart';
import '../../../../shared/widgets/variable_scope.dart';
import '../../../collections/presentation/collection_providers.dart';
import '../../../workspace/presentation/workspace_controller.dart';
import '../../domain/models/request_auth.dart';

/// Authorization tab of a request.
class AuthEditor extends ConsumerWidget {
  const AuthEditor({super.key, required this.tabId});
  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth =
        ref.watch(requestTabProvider(tabId).select((t) => t?.draft.auth)) ??
        const NoAuth();
    final collectionId = ref.watch(
      requestTabProvider(tabId).select((t) => t?.draft.collectionId),
    );
    return AuthForm(
      auth: auth,
      allowInherit: true,
      collectionId: collectionId,
      onChanged: (a) => ref
          .read(workspaceProvider.notifier)
          .updateDraft(tabId, (d) => d.copyWith(auth: a)),
    );
  }
}

/// Edits a [RequestAuth]. Requests may choose "Inherit auth from parent"
/// ([allowInherit]); [collectionId] is the collection they inherit from.
class AuthForm extends ConsumerWidget {
  const AuthForm({
    super.key,
    required this.auth,
    required this.onChanged,
    this.allowInherit = false,
    this.collectionId,
    this.noAuthHint = 'This request does not use any authorization.',
  });

  final RequestAuth auth;
  final ValueChanged<RequestAuth> onChanged;
  final bool allowInherit;
  final String? collectionId;
  final String noAuthHint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = this.auth;
    void set(RequestAuth a) => onChanged(a);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _Row(
          label: 'Type',
          child: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 300,
              child: DropdownButtonFormField<AuthType>(
                key: ValueKey(auth.type),
                initialValue: auth.type,
                isDense: true,
                isExpanded: true,
                items: [
                  for (final t in AuthType.values)
                    if (allowInherit || t != AuthType.inherit)
                      DropdownMenuItem(
                        value: t,
                        child: Text(t.label, overflow: TextOverflow.ellipsis),
                      ),
                ],
                onChanged: (t) {
                  if (t != null && t != auth.type) set(RequestAuth.empty(t));
                },
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        switch (auth) {
          InheritAuth() => _InheritedAuthInfo(collectionId: collectionId),
          NoAuth() => _Hint(noAuthHint),
          final BearerAuth a => Column(
            children: [
              _Row(
                label: 'Token',
                child: SecretField(
                  value: a.token,
                  hint: 'Token or {{variable}}',
                  onChanged: (v) => set(BearerAuth(token: v)),
                ),
              ),
              const _Hint(
                'Sent as "Authorization: Bearer <token>". Stored in the system keychain.',
              ),
            ],
          ),
          final BasicAuth a => Column(
            children: [
              _Row(
                label: 'Username',
                child: VariableField(
                  value: a.username,
                  onChanged: (v) => set(a.copyWith(username: v)),
                ),
              ),
              _Row(
                label: 'Password',
                child: SecretField(
                  value: a.password,
                  onChanged: (v) => set(a.copyWith(password: v)),
                ),
              ),
              const _Hint(
                'Credentials are Base64 encoded into the Authorization header. The password is stored in the system keychain.',
              ),
            ],
          ),
          final ApiKeyAuth a => Column(
            children: [
              _Row(
                label: 'Key',
                child: VariableField(
                  value: a.key,
                  hint: 'X-API-Key',
                  onChanged: (v) => set(a.copyWith(key: v)),
                ),
              ),
              _Row(
                label: 'Value',
                child: SecretField(
                  value: a.value,
                  onChanged: (v) => set(a.copyWith(value: v)),
                ),
              ),
              _Row(
                label: 'Add to',
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SegmentedButton<ApiKeyLocation>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: ApiKeyLocation.header,
                        label: Text('Header'),
                      ),
                      ButtonSegment(
                        value: ApiKeyLocation.query,
                        label: Text('Query params'),
                      ),
                    ],
                    selected: {a.location},
                    onSelectionChanged: (s) =>
                        set(a.copyWith(location: s.first)),
                  ),
                ),
              ),
            ],
          ),
          final OAuth2Auth a => _OAuth2Editor(auth: a, onChanged: set),
        },
      ],
    );
  }
}

/// Explains what an inheriting request sends, with a link to the collection.
class _InheritedAuthInfo extends ConsumerWidget {
  const _InheritedAuthInfo({required this.collectionId});
  final String? collectionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = collectionId;
    if (id == null) {
      return const _Hint(
        'This request is not saved in a collection yet, so no authorization '
        'is inherited. Save it to a collection to use the collection\'s auth.',
      );
    }
    final name =
        ref.watch(
          collectionTreesProvider.select(
            (t) => t.value
                ?.where((c) => c.collection.id == id)
                .firstOrNull
                ?.collection
                .name,
          ),
        ) ??
        'collection';
    final inherited = ref.watch(collectionSettingsProvider(id)).value?.auth;
    final text = inherited == null || inherited is NoAuth
        ? 'The "$name" collection has no authorization, so none is sent.'
        : 'This request uses the ${inherited.type.label} authorization of the '
              '"$name" collection.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Hint(text),
        Padding(
          padding: const EdgeInsets.only(left: 130),
          child: TextButton.icon(
            key: const ValueKey('edit-collection-auth'),
            onPressed: () =>
                ref.read(workspaceProvider.notifier).openCollection(id, name),
            icon: const Icon(Icons.open_in_new, size: 15),
            label: const Text('Edit collection authorization'),
          ),
        ),
      ],
    );
  }
}

class _OAuth2Editor extends ConsumerStatefulWidget {
  const _OAuth2Editor({required this.auth, required this.onChanged});
  final OAuth2Auth auth;
  final ValueChanged<RequestAuth> onChanged;

  @override
  ConsumerState<_OAuth2Editor> createState() => _OAuth2EditorState();
}

class _OAuth2EditorState extends ConsumerState<_OAuth2Editor> {
  bool _busy = false;

  OAuth2Auth get a => widget.auth;

  Future<void> _getToken() async {
    final resolver = VariableScope.read(ref, context);
    final client = ref.read(oauth2ClientProvider);
    final tokenUrl = Uri.tryParse(resolver(a.tokenUrl));
    if (tokenUrl == null || !tokenUrl.hasScheme) {
      showToast(context, 'Enter a valid token URL.', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final token = switch (a.grantType) {
        OAuth2GrantType.clientCredentials => await client.clientCredentials(
          tokenEndpoint: tokenUrl,
          clientId: resolver(a.clientId),
          clientSecret: resolver(a.clientSecret),
          scope: resolver(a.scope),
        ),
        OAuth2GrantType.authorizationCode => await client.authorizationCode(
          authorizationEndpoint:
              Uri.tryParse(resolver(a.authUrl)) ??
              (throw const ValidationFailure(
                'Enter a valid authorization URL.',
              )),
          tokenEndpoint: tokenUrl,
          clientId: resolver(a.clientId),
          clientSecret: resolver(a.clientSecret),
          scope: resolver(a.scope),
          openUrl: (url) =>
              launchUrl(url, mode: LaunchMode.externalApplication),
        ),
      };
      widget.onChanged(
        a.copyWith(
          accessToken: token.accessToken,
          refreshToken: token.refreshToken ?? '',
          expiresAt: () => token.expiresAt,
        ),
      );
      if (mounted) showToast(context, 'Access token received');
    } catch (e) {
      if (mounted) showToast(context, e.userMessage, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    final resolver = VariableScope.read(ref, context);
    setState(() => _busy = true);
    try {
      final token = await ref
          .read(oauth2ClientProvider)
          .refresh(
            tokenEndpoint: Uri.parse(resolver(a.tokenUrl)),
            clientId: resolver(a.clientId),
            clientSecret: resolver(a.clientSecret),
            refreshToken: a.refreshToken,
          );
      widget.onChanged(
        a.copyWith(
          accessToken: token.accessToken,
          refreshToken: token.refreshToken ?? a.refreshToken,
          expiresAt: () => token.expiresAt,
        ),
      );
      if (mounted) showToast(context, 'Access token refreshed');
    } catch (e) {
      if (mounted) showToast(context, e.userMessage, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final expiry = a.expiresAt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Row(
          label: 'Access token',
          child: SecretField(
            value: a.accessToken,
            hint: 'Paste a token or use "Get new access token"',
            onChanged: (v) => widget.onChanged(a.copyWith(accessToken: v)),
          ),
        ),
        if (expiry != null)
          _Hint(
            a.isExpired
                ? 'Token expired ${Formatters.relativeTime(expiry)}.'
                : 'Token expires ${Formatters.dateTime(expiry)}.',
            color: a.isExpired ? colors.warning : null,
          ),
        _Row(
          label: 'Header prefix',
          child: SizedBox(
            width: 160,
            child: VariableField(
              value: a.headerPrefix,
              onChanged: (v) => widget.onChanged(a.copyWith(headerPrefix: v)),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Divider(color: colors.border),
        const SizedBox(height: 6),
        Text(
          'Configure new token',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        _Row(
          label: 'Grant type',
          child: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 300,
              child: DropdownButtonFormField<OAuth2GrantType>(
                key: ValueKey(a.grantType),
                initialValue: a.grantType,
                isDense: true,
                items: [
                  for (final g in OAuth2GrantType.values)
                    DropdownMenuItem(value: g, child: Text(g.label)),
                ],
                onChanged: (g) => widget.onChanged(a.copyWith(grantType: g)),
              ),
            ),
          ),
        ),
        if (a.grantType == OAuth2GrantType.authorizationCode)
          _Row(
            label: 'Auth URL',
            child: VariableField(
              value: a.authUrl,
              hint: 'https://auth.example.com/authorize',
              onChanged: (v) => widget.onChanged(a.copyWith(authUrl: v)),
            ),
          ),
        _Row(
          label: 'Token URL',
          child: VariableField(
            value: a.tokenUrl,
            hint: 'https://auth.example.com/token',
            onChanged: (v) => widget.onChanged(a.copyWith(tokenUrl: v)),
          ),
        ),
        _Row(
          label: 'Client ID',
          child: VariableField(
            value: a.clientId,
            onChanged: (v) => widget.onChanged(a.copyWith(clientId: v)),
          ),
        ),
        _Row(
          label: 'Client secret',
          child: SecretField(
            value: a.clientSecret,
            hint: a.grantType == OAuth2GrantType.authorizationCode
                ? 'Optional for public clients'
                : null,
            onChanged: (v) => widget.onChanged(a.copyWith(clientSecret: v)),
          ),
        ),
        _Row(
          label: 'Scope',
          child: VariableField(
            value: a.scope,
            hint: 'read write',
            onChanged: (v) => widget.onChanged(a.copyWith(scope: v)),
          ),
        ),
        if (a.grantType == OAuth2GrantType.authorizationCode)
          const _Hint(
            'Opens your browser. Register http://127.0.0.1 (any port) as a redirect URI with your '
            'provider; Vesper listens on a temporary loopback port and uses PKCE.',
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            FilledButton(
              onPressed: _busy ? null : _getToken,
              child: _busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('Get new access token'),
            ),
            const SizedBox(width: 8),
            if (a.refreshToken.isNotEmpty)
              OutlinedButton(
                onPressed: _busy ? null : _refresh,
                child: const Text('Refresh token'),
              ),
          ],
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        SizedBox(
          width: 130,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              color: context.colors.textSecondary,
            ),
          ),
        ),
        Expanded(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: child,
          ),
        ),
      ],
    ),
  );
}

class _Hint extends StatelessWidget {
  const _Hint(this.text, {this.color});
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(130, 4, 0, 6),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12,
        color: color ?? context.colors.textMuted,
        height: 1.4,
      ),
    ),
  );
}
