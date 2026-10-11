import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/storage/app_database.dart';
import '../../settings/data/settings_repository.dart';
import '../data/workspace_repository.dart';
import '../domain/workspace.dart';

final workspaceRepositoryProvider = Provider<WorkspaceRepository>(
  (ref) => WorkspaceRepository(
    ref.watch(databaseProvider),
    ref.watch(vaultProvider),
  ),
);

/// Workspace selected at startup (overridden in bootstrap).
final initialWorkspaceIdProvider = Provider<String>(
  (ref) => defaultWorkspaceId,
);

/// Id of the workspace whose data the app shows. Repositories watch it, so
/// switching rescopes collections, environments and history.
final activeWorkspaceIdProvider = NotifierProvider<ActiveWorkspace, String>(
  ActiveWorkspace.new,
);

final workspacesProvider = StreamProvider<List<Workspace>>(
  (ref) => ref.watch(workspaceRepositoryProvider).watchAll(),
);

final activeWorkspaceProvider = Provider<Workspace?>((ref) {
  final id = ref.watch(activeWorkspaceIdProvider);
  final all = ref.watch(workspacesProvider).value ?? const [];
  return all.where((w) => w.id == id).firstOrNull;
});

/// The environment selected in the active workspace.
final activeEnvironmentIdProvider = Provider<String?>(
  (ref) => ref.watch(activeWorkspaceProvider)?.activeEnvironmentId,
);

class ActiveWorkspace extends Notifier<String> {
  @override
  String build() => ref.watch(initialWorkspaceIdProvider);

  WorkspaceRepository get _repo => ref.read(workspaceRepositoryProvider);

  Future<void> select(String id) async {
    if (id == state) return;
    state = id;
    await ref
        .read(settingsRepositoryProvider)
        .write(SettingsRepository.activeWorkspaceKey, id);
  }

  /// Creates a workspace and switches to it.
  Future<Workspace> create(String name) async {
    final workspace = await _repo.create(name);
    await select(workspace.id);
    return workspace;
  }

  Future<void> rename(String id, String name) => _repo.rename(id, name);

  /// Deletes a workspace and its data, leaving it first when it is active.
  Future<void> delete(String id) async {
    if (id == defaultWorkspaceId) {
      return _repo.delete(id); // throws the explanatory failure
    }
    if (id == state) await select(defaultWorkspaceId);
    await _repo.delete(id);
  }

  Future<void> setActiveEnvironment(String? environmentId) =>
      _repo.setActiveEnvironment(state, environmentId);
}
