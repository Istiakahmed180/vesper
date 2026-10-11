import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase/supabase.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/storage/app_database.dart';
import '../../auth/domain/auth_models.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../workspace/presentation/workspace_controller.dart';
import '../../workspaces/presentation/workspace_providers.dart';
import '../data/drift_local_sync_store.dart';
import '../data/supabase_cloud.dart';
import '../domain/sync_engine.dart';

enum CloudSyncPhase {
  /// Cloud sync is not configured in this build.
  unavailable,

  /// No Google account is signed in.
  signedOut,
  connecting,
  syncing,
  synced,

  /// The sync server could not be reached; retried automatically.
  offline,
  error,

  /// This computer holds data of a different account; the user decides.
  accountChanged,
}

@immutable
class CloudSyncState {
  const CloudSyncState(
    this.phase, {
    this.lastSyncedAt,
    this.message,
    this.previousAccount,
  });

  final CloudSyncPhase phase;
  final DateTime? lastSyncedAt;
  final String? message;

  /// Email of the account whose data is on this computer
  /// ([CloudSyncPhase.accountChanged]).
  final String? previousAccount;

  bool get isActive =>
      phase == CloudSyncPhase.syncing ||
      phase == CloudSyncPhase.synced ||
      phase == CloudSyncPhase.offline ||
      phase == CloudSyncPhase.error;

  CloudSyncState copyWith(CloudSyncPhase phase, {String? message}) =>
      CloudSyncState(
        phase,
        lastSyncedAt: lastSyncedAt,
        message: message,
        previousAccount: previousAccount,
      );
}

final cloudClientProvider = Provider<SupabaseClient?>((ref) {
  final config = ref.watch(appConfigProvider);
  if (!config.isCloudConfigured) return null;
  final client = SupabaseClient(config.supabaseUrl, config.supabaseAnonKey);
  ref.onDispose(client.dispose);
  return client;
});

final cloudSyncProvider = NotifierProvider<CloudSyncController, CloudSyncState>(
  CloudSyncController.new,
);

/// Connects cloud sync while a Google account is signed in: pulls the
/// account's data, uploads local changes shortly after they happen, and
/// listens for changes from other devices.
class CloudSyncController extends Notifier<CloudSyncState> {
  static const ownerIdKey = 'cloud.user_id';
  static const ownerEmailKey = 'cloud.user_email';
  static const _pushDelay = Duration(milliseconds: 1500);
  static const _pullDelay = Duration(milliseconds: 400);
  static const _interval = Duration(seconds: 60);

  CloudAuth? _auth;
  SupabaseCloudStore? _store;
  SyncEngine? _engine;
  DriftLocalSyncStore? _local;
  final _subscriptions = <StreamSubscription<Object?>>[];
  Timer? _pushTimer;
  Timer? _pullTimer;
  Timer? _periodic;
  Future<void>? _running;
  bool _again = false;
  int _generation = 0;
  String? _connectedAs;

  @override
  CloudSyncState build() {
    final client = ref.watch(cloudClientProvider);
    ref.onDispose(_stop);
    if (client == null) return const CloudSyncState(CloudSyncPhase.unavailable);
    _auth = CloudAuth(
      client: client,
      vault: ref.watch(vaultProvider),
      logger: ref.watch(loggerProvider),
    );
    _store = SupabaseCloudStore(client);
    _local = DriftLocalSyncStore(
      ref.watch(databaseProvider),
      ref.watch(vaultProvider),
    );
    _engine = SyncEngine(local: _local!, cloud: _store!);
    ref.listen(
      authSessionProvider,
      (_, next) => unawaited(_onAccount(next.value)),
      fireImmediately: true,
    );
    return const CloudSyncState(CloudSyncPhase.signedOut);
  }

  Future<void> _onAccount(AuthSession? session) async {
    if (session == null) {
      if (_connectedAs != null) await _disconnect();
      return;
    }
    if (_connectedAs == session.account.email) return;
    await _connect(session);
  }

  Future<void> _connect(AuthSession session) async {
    final generation = ++_generation;
    _connectedAs = session.account.email;
    state = const CloudSyncState(CloudSyncPhase.connecting);
    try {
      final user = await _auth!.restore() ?? await _signIn();
      if (generation != _generation) return;
      final settings = ref.read(settingsRepositoryProvider);
      final owner = await settings.read(ownerIdKey);
      if (owner != null && owner != user.id) {
        state = CloudSyncState(
          CloudSyncPhase.accountChanged,
          previousAccount:
              await settings.read(ownerEmailKey) ?? 'another account',
        );
        return;
      }
      if (owner == null) await _adopt(user, merge: true);
      _start();
    } catch (e) {
      if (generation != _generation) return;
      _connectedAs = null;
      state = CloudSyncState(
        e is NetworkFailure ? CloudSyncPhase.offline : CloudSyncPhase.error,
        message: e.userMessage,
      );
    }
  }

  Future<User> _signIn() async {
    final idToken = await ref.read(authRepositoryProvider).currentIdToken();
    if (idToken == null) {
      throw const SyncFailure(
        'Google did not provide an ID token. Sign out and sign in again.',
      );
    }
    return _auth!.signInWithGoogle(idToken);
  }

  /// Makes this computer's data belong to [user]. With [merge] the local
  /// data is uploaded into the account; otherwise it is replaced.
  Future<void> _adopt(User user, {required bool merge}) async {
    final settings = ref.read(settingsRepositoryProvider);
    await _local!.reset();
    if (merge) {
      await _local!.enqueueAll();
    } else {
      await ref
          .read(activeWorkspaceIdProvider.notifier)
          .select(defaultWorkspaceId);
      await ref.read(databaseProvider).wipeContent();
      // Secrets of the previous account's requests; sessions stay.
      await ref
          .read(vaultProvider)
          .deleteWhere((k) => !k.startsWith('vesper.auth.'));
      ref.invalidate(workspaceProvider);
    }
    await settings.write(ownerIdKey, user.id);
    await settings.write(ownerEmailKey, user.email ?? _connectedAs ?? '');
  }

  /// Resolves [CloudSyncPhase.accountChanged].
  Future<void> resolveAccountChange({required bool replaceLocalData}) async {
    final user = _auth?.currentUser;
    if (user == null || state.phase != CloudSyncPhase.accountChanged) return;
    state = const CloudSyncState(CloudSyncPhase.connecting);
    try {
      await _adopt(user, merge: !replaceLocalData);
      _start();
    } catch (e) {
      state = CloudSyncState(CloudSyncPhase.error, message: e.userMessage);
    }
  }

  void _start() {
    _stopListening();
    final db = ref.read(databaseProvider);
    _subscriptions
      ..add(
        db.select(db.syncOutbox).watch().listen((rows) {
          if (rows.isEmpty) return;
          _pushTimer?.cancel();
          _pushTimer = Timer(_pushDelay, syncNow);
        }),
      )
      ..add(
        _store!.remoteChanges().listen((_) {
          _pullTimer?.cancel();
          _pullTimer = Timer(_pullDelay, syncNow);
        }),
      );
    _periodic = Timer.periodic(_interval, (_) => syncNow());
    unawaited(syncNow());
  }

  /// Pulls and pushes now; calls made while a sync runs queue one more.
  Future<void> syncNow() async {
    final engine = _engine;
    if (engine == null || _connectedAs == null) return;
    if (state.phase == CloudSyncPhase.accountChanged ||
        state.phase == CloudSyncPhase.connecting) {
      return;
    }
    if (_running != null) {
      _again = true;
      return _running;
    }
    final generation = _generation;
    _running = () async {
      do {
        _again = false;
        state = state.copyWith(CloudSyncPhase.syncing);
        try {
          await engine.sync();
          if (generation != _generation) return;
          state = CloudSyncState(
            CloudSyncPhase.synced,
            lastSyncedAt: DateTime.now(),
          );
        } catch (e) {
          if (generation != _generation) return;
          state = state.copyWith(
            e is NetworkFailure ? CloudSyncPhase.offline : CloudSyncPhase.error,
            message: e.userMessage,
          );
          ref.read(loggerProvider).warning('Cloud sync failed', {
            'error': e.runtimeType.toString(),
          });
          return;
        }
      } while (_again);
    }();
    try {
      await _running;
    } finally {
      _running = null;
    }
  }

  Future<void> _disconnect() async {
    _generation++;
    _connectedAs = null;
    _stopListening();
    await _auth?.signOut();
    state = const CloudSyncState(CloudSyncPhase.signedOut);
  }

  void _stopListening() {
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    _subscriptions.clear();
    _pushTimer?.cancel();
    _pullTimer?.cancel();
    _periodic?.cancel();
  }

  void _stop() {
    _generation++;
    _stopListening();
  }
}
