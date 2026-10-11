import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/errors/app_failure.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../settings/data/settings_repository.dart';
import '../../workspaces/presentation/workspace_providers.dart';
import '../data/github_api.dart';
import '../data/github_auth_repository.dart';
import '../domain/github_models.dart';

final githubApiProvider = Provider<GitHubApi>(
  (ref) => GitHubApi(logger: ref.watch(loggerProvider)),
);

final githubAuthRepositoryProvider = Provider<GitHubAuthRepository>(
  (ref) => GitHubAuthRepository(
    api: ref.watch(githubApiProvider),
    vault: ref.watch(vaultProvider),
    config: ref.watch(appConfigProvider),
    logger: ref.watch(loggerProvider),
  ),
);

final githubSessionProvider =
    AsyncNotifierProvider<GitHubController, GitHubSession?>(
      GitHubController.new,
    );

class GitHubController extends AsyncNotifier<GitHubSession?> {
  GitHubAuthRepository get _repo => ref.read(githubAuthRepositoryProvider);

  @override
  Future<GitHubSession?> build() =>
      ref.watch(githubAuthRepositoryProvider).restore();

  Future<DeviceCode> startConnect() async {
    // Only one account at a time.
    final google = await ref.read(authSessionProvider.future);
    if (google != null) {
      throw ValidationFailure(
        'You are signed in with Google (${google.account.email}). '
        'Sign out first to connect GitHub.',
      );
    }
    return _repo.startDeviceFlow();
  }

  Future<void> completeConnect(
    DeviceCode code, {
    Future<void>? cancelled,
  }) async {
    final session = await _repo.completeDeviceFlow(code, cancelled: cancelled);
    state = AsyncData(session);
  }

  Future<void> disconnect() async {
    await _repo.disconnect();
    // Sync targets of every workspace belong to this GitHub account.
    await ref
        .read(settingsRepositoryProvider)
        .removeWithPrefix(SettingsRepository.syncTargetKey(''));
    ref.invalidate(syncTargetProvider);
    state = const AsyncData(null);
  }

  /// Called when an API call reports the token was revoked or expired.
  Future<void> handleFailure(Object error) async {
    if (error is AuthFailure && error.kind == AuthFailureKind.expired) {
      await _repo.disconnect();
      state = const AsyncData(null);
    }
  }
}

final githubReposProvider = FutureProvider.autoDispose<List<GitHubRepo>>((
  ref,
) async {
  final session = await ref.watch(githubSessionProvider.future);
  if (session == null) return const [];
  try {
    return await ref.read(githubApiProvider).listRepos(session.accessToken);
  } catch (e) {
    unawaited(ref.read(githubSessionProvider.notifier).handleFailure(e));
    rethrow;
  }
});

final syncTargetProvider =
    AsyncNotifierProvider<SyncTargetController, SyncTarget?>(
      SyncTargetController.new,
    );

/// GitHub repository the active workspace syncs with.
class SyncTargetController extends AsyncNotifier<SyncTarget?> {
  late String _key;

  @override
  Future<SyncTarget?> build() async {
    _key = SettingsRepository.syncTargetKey(
      ref.watch(activeWorkspaceIdProvider),
    );
    final json = await ref.read(settingsRepositoryProvider).readJson(_key);
    if (json == null) return null;
    final target = SyncTarget.fromJson(json);
    return target.repo.isEmpty ? null : target;
  }

  Future<void> select(SyncTarget target) async {
    await ref.read(settingsRepositoryProvider).writeJson(_key, target.toJson());
    state = AsyncData(target);
  }

  Future<void> clear() async {
    await ref.read(settingsRepositoryProvider).remove(_key);
    state = const AsyncData(null);
  }
}
