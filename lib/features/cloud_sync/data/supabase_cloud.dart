import 'dart:async';
import 'dart:convert';

import 'package:supabase/supabase.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/oauth/loopback_receiver.dart';
import '../../../core/security/secret_vault.dart';
import '../domain/cloud_models.dart';

/// Supabase sign-in for cloud sync. The Supabase session is kept in the OS
/// vault and refreshed by the client.
class CloudAuth {
  CloudAuth({required this.client, required this.vault, required this.logger});

  final SupabaseClient client;
  final SecretVault vault;
  final AppLogger logger;
  StreamSubscription<AuthState>? _persist;

  User? get currentUser => client.auth.currentUser;

  void _persistSessions() {
    _persist ??= client.auth.onAuthStateChange.listen((state) async {
      final session = state.session;
      if (session != null) {
        await vault.write(VaultKeys.cloudSession, jsonEncode(session.toJson()));
      }
    });
  }

  /// Restores the stored session. Null when there is none or it was revoked.
  Future<User?> restore() async {
    _persistSessions();
    final raw = await vault.read(VaultKeys.cloudSession);
    if (raw == null) return null;
    try {
      return (await client.auth.recoverSession(raw)).user;
    } on AuthRetryableFetchException {
      throw const NetworkFailure(
        NetworkFailureKind.unknown,
        'Could not reach the sync server.',
      );
    } on AuthException catch (e) {
      logger.info('Stored cloud session rejected', {'status': e.statusCode});
      await vault.delete(VaultKeys.cloudSession);
      return null;
    }
  }

  /// Exchanges a Google ID token for a Supabase session.
  Future<User> signInWithGoogle(String idToken) async {
    _persistSessions();
    try {
      final response = await client.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
      );
      final user = response.user;
      if (user == null) throw const SyncFailure('Cloud sign-in failed.');
      logger.info('Cloud sync signed in');
      return user;
    } on AuthRetryableFetchException {
      throw const NetworkFailure(
        NetworkFailureKind.unknown,
        'Could not reach the sync server.',
      );
    } on AuthException catch (e) {
      throw SyncFailure(
        'Cloud sign-in was rejected: ${e.message}. Check that Google sign-in '
        'is enabled in Supabase with this app\'s client ID.',
      );
    }
  }

  /// Signs in with GitHub through Supabase (PKCE, browser, loopback
  /// redirect) and returns the GitHub access token Supabase obtained, which
  /// Vesper also uses for repository sync.
  Future<({User user, String githubToken})> signInWithGitHub({
    required Future<bool> Function(Uri url) openUrl,
    required String scopes,
    Future<void>? cancelled,
  }) async {
    _persistSessions();
    final receiver = await LoopbackReceiver.start();
    try {
      final OAuthResponse oauth;
      try {
        oauth = await client.auth.getOAuthSignInUrl(
          provider: OAuthProvider.github,
          redirectTo: receiver.redirectUri,
          scopes: scopes,
        );
      } on AuthException catch (e) {
        throw SyncFailure('GitHub sign-in could not start: ${e.message}');
      }
      if (!await openUrl(Uri.parse(oauth.url))) {
        throw const AuthFailure(
          AuthFailureKind.invalidResponse,
          'Could not open the browser.',
        );
      }
      final params = await receiver.waitForCallback(
        expectedState: null,
        cancelled: cancelled,
      );
      final Session session;
      try {
        session = (await client.auth.exchangeCodeForSession(
          params['code']!,
        )).session;
      } on AuthRetryableFetchException {
        throw const NetworkFailure(
          NetworkFailureKind.unknown,
          'Could not reach the sync server.',
        );
      } on AuthException catch (e) {
        throw SyncFailure('GitHub sign-in was rejected: ${e.message}');
      }
      final token = session.providerToken;
      if (token == null || token.isEmpty) {
        throw const SyncFailure('GitHub did not return an access token.');
      }
      logger.info('Cloud sync signed in', {'provider': 'github'});
      return (user: session.user, githubToken: token);
    } finally {
      await receiver.close();
    }
  }

  Future<void> signOut() async {
    await _persist?.cancel();
    _persist = null;
    try {
      await client.auth.signOut();
    } catch (_) {
      // Signing out locally is enough when offline.
    }
    await vault.delete(VaultKeys.cloudSession);
  }
}

/// Keeps the PKCE code verifier between starting a browser sign-in and
/// exchanging its code; both happen in the same app session.
class MemoryAuthStorage extends GotrueAsyncStorage {
  final _items = <String, String>{};

  @override
  Future<String?> getItem({required String key}) async => _items[key];

  @override
  Future<void> setItem({required String key, required String value}) async =>
      _items[key] = value;

  @override
  Future<void> removeItem({required String key}) async => _items.remove(key);
}

/// [CloudStore] on the Supabase `sync_items` table (see
/// supabase/migrations/0001_vesper_sync.sql).
class SupabaseCloudStore implements CloudStore {
  SupabaseCloudStore(this.client);

  final SupabaseClient client;
  static const table = 'sync_items';
  static const _pageSize = 1000;

  String get _userId {
    final user = client.auth.currentUser;
    if (user == null) throw const SyncFailure('Not signed in to cloud sync.');
    return user.id;
  }

  static const sharedTable = 'shared_items';

  @override
  Future<void> upsert(List<CloudItem> items) async {
    final userId = _userId;
    final personal = items.where((i) => i.scope == null).toList();
    final shared = items.where((i) => i.scope != null).toList();
    for (final (rows, tableName, conflict) in [
      (
        [
          for (final item in personal) {'user_id': userId, ..._row(item)},
        ],
        table,
        'user_id,kind,id',
      ),
      (
        [
          for (final item in shared)
            {'workspace_id': item.scope, ..._row(item)},
        ],
        sharedTable,
        'workspace_id,kind,id',
      ),
    ]) {
      for (var i = 0; i < rows.length; i += 200) {
        final chunk = rows.skip(i).take(200).toList();
        await _guard(
          () => client.from(tableName).upsert(chunk, onConflict: conflict),
        );
      }
    }
  }

  static Map<String, Object?> _row(CloudItem item) => {
    'kind': item.kind.name,
    'id': item.id,
    'data': item.data,
    'deleted': item.deleted,
    'client_updated_at': item.clientUpdatedAt.toUtc().toIso8601String(),
  };

  @override
  Future<List<CloudItem>> changesSince(
    DateTime? cursor, {
    String? scope,
  }) async {
    final userId = _userId;
    final out = <CloudItem>[];
    for (var offset = 0; ; offset += _pageSize) {
      var query = client
          .from(scope == null ? table : sharedTable)
          .select(
            'kind, id, data, deleted, client_updated_at, server_updated_at',
          );
      query = scope == null
          ? query.eq('user_id', userId)
          : query.eq('workspace_id', scope);
      if (cursor != null) {
        query = query.gt('server_updated_at', cursor.toUtc().toIso8601String());
      }
      final rows = await _guard(
        () => query
            .order('server_updated_at')
            .range(offset, offset + _pageSize - 1),
      );
      for (final row in rows) {
        final kind = CloudKind.parse('${row['kind']}');
        if (kind == null) continue;
        final data = row['data'];
        out.add(
          CloudItem(
            kind: kind,
            id: '${row['id']}',
            data: row['deleted'] == true || data is! Map
                ? null
                : data.cast<String, Object?>(),
            clientUpdatedAt: DateTime.parse('${row['client_updated_at']}'),
            serverUpdatedAt: DateTime.parse('${row['server_updated_at']}'),
            scope: scope,
          ),
        );
      }
      if (rows.length < _pageSize) return out;
    }
  }

  @override
  Future<Map<String, WorkspaceRole>> memberships() async {
    final userId = _userId;
    try {
      await _guard(() => client.rpc<Object?>('accept_workspace_invites'));
    } on SyncFailure catch (e) {
      // Older projects without team workspaces: personal sync still works.
      if (e.message.contains('missing')) return {};
      rethrow;
    }
    final rows = await _guard(
      () => client
          .from('workspace_members')
          .select('workspace_id, role')
          .eq('user_id', userId),
    );
    return {
      for (final row in rows)
        '${row['workspace_id']}': row['role'] == 'owner'
            ? WorkspaceRole.owner
            : WorkspaceRole.member,
    };
  }

  // ------------------------------------------------------- team management

  /// Creates the shared workspace (the caller becomes its owner).
  Future<void> shareWorkspace(String id, String name) => _guard(
    () => client.rpc<Object?>(
      'share_workspace',
      params: {'ws': id, 'ws_name': name},
    ),
  );

  Future<List<WorkspaceMember>> members(String workspaceId) async {
    final rows = await _guard(
      () => client
          .from('workspace_members')
          .select('user_id, email, role')
          .eq('workspace_id', workspaceId)
          .order('added_at'),
    );
    return [
      for (final row in rows)
        WorkspaceMember(
          userId: '${row['user_id']}',
          email: '${row['email'] ?? ''}',
          role: row['role'] == 'owner'
              ? WorkspaceRole.owner
              : WorkspaceRole.member,
        ),
    ];
  }

  Future<List<String>> invites(String workspaceId) async {
    final rows = await _guard(
      () => client
          .from('workspace_invites')
          .select('email')
          .eq('workspace_id', workspaceId)
          .order('created_at'),
    );
    return [for (final row in rows) '${row['email']}'];
  }

  /// Invites [email]; inviting the same address again is not an error.
  Future<void> invite(String workspaceId, String email) async {
    try {
      await client.from('workspace_invites').insert({
        'workspace_id': workspaceId,
        'email': email.trim().toLowerCase(),
        'invited_by': _userId,
      });
    } on PostgrestException catch (e) {
      if (e.code == '23505') return; // already invited
      await _guard(() => Future<void>.error(e));
    }
  }

  Future<void> cancelInvite(String workspaceId, String email) => _guard(
    () => client
        .from('workspace_invites')
        .delete()
        .eq('workspace_id', workspaceId)
        .eq('email', email),
  );

  /// Removes [userId] (owner) or the caller (leaving).
  Future<void> removeMember(String workspaceId, String userId) => _guard(
    () => client
        .from('workspace_members')
        .delete()
        .eq('workspace_id', workspaceId)
        .eq('user_id', userId),
  );

  /// Deletes a shared workspace with everything in it (owner only).
  Future<void> deleteSharedWorkspace(String workspaceId) => _guard(
    () => client.from('team_workspaces').delete().eq('id', workspaceId),
  );

  String get currentUserId => _userId;

  /// Fires when another device changes this user's items.
  Stream<void> remoteChanges() {
    final userId = _userId;
    late final RealtimeChannel channel;
    late final StreamController<void> controller;
    controller = StreamController<void>(
      onCancel: () async {
        await client.removeChannel(channel);
        await controller.close();
      },
    );
    // Shared items and memberships are limited to what the user may see by
    // Row Level Security.
    channel = client
        .channel('vesper-sync-$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: table,
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (_) => controller.add(null),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: sharedTable,
          callback: (_) => controller.add(null),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'workspace_members',
          callback: (_) => controller.add(null),
        )
        .subscribe();
    return controller.stream;
  }

  static Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on PostgrestException catch (e) {
      if (e.code == '42P01' || e.code == 'PGRST205' || e.code == 'PGRST202') {
        throw const SyncFailure(
          'A sync table or function is missing. Run the SQL files in '
          'supabase/migrations in the Supabase SQL Editor.',
        );
      }
      throw SyncFailure('The sync server rejected the change: ${e.message}');
    } on AuthException {
      throw const SyncFailure('Your cloud session expired. Sign in again.');
    } on Exception catch (e) {
      throw NetworkFailure(
        NetworkFailureKind.unknown,
        'Could not reach the sync server.',
        debugDetail: '$e',
      );
    }
  }
}
