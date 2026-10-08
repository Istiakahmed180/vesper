import 'package:drift/drift.dart';

import '../../../core/storage/app_database.dart';
import '../../github/data/github_api.dart';
import '../../github/domain/github_models.dart';
import '../domain/sync_models.dart';

class DriftSyncStateStore implements SyncStateStore {
  DriftSyncStateStore(this._db);
  final AppDatabase _db;

  @override
  Future<List<SyncRecord>> all(String remote) async {
    final rows = await (_db.select(
      _db.syncStates,
    )..where((s) => s.remote.equals(remote))).get();
    return [
      for (final r in rows)
        SyncRecord(
          itemKey: r.itemKey,
          remote: r.remote,
          path: r.path,
          remoteSha: r.remoteSha,
          contentHash: r.contentHash,
          syncedAt: r.syncedAt,
        ),
    ];
  }

  @override
  Future<void> put(SyncRecord record) => _db
      .into(_db.syncStates)
      .insertOnConflictUpdate(
        SyncStatesCompanion.insert(
          itemKey: record.itemKey,
          remote: record.remote,
          path: record.path,
          remoteSha: record.remoteSha,
          contentHash: record.contentHash,
          syncedAt: record.syncedAt,
        ),
      );

  @override
  Future<void> delete(String itemKey, String remote) => (_db.delete(
    _db.syncStates,
  )..where((s) => s.itemKey.equals(itemKey) & s.remote.equals(remote))).go();
}

/// [RemoteFileStore] backed by the GitHub contents API.
class GitHubFileStore implements RemoteFileStore {
  GitHubFileStore({
    required this.api,
    required this.token,
    required this.target,
  });

  final GitHubApi api;
  final String token;
  final SyncTarget target;

  @override
  String get remoteKey => target.remoteKey;

  @override
  Future<RemoteFileData?> read(String path) async {
    final file = await api.getFile(token, target.repo, target.branch, path);
    return file == null
        ? null
        : RemoteFileData(path: file.path, sha: file.sha, content: file.content);
  }

  @override
  Future<List<String>> listFiles(String directory) async {
    final entries = await api.listDirectory(
      token,
      target.repo,
      target.branch,
      directory,
    );
    return [
      for (final e in entries)
        if (e.isFile) e.path,
    ];
  }

  @override
  Future<String> write(
    String path,
    String content, {
    required String message,
    String? expectedSha,
  }) => api.putFile(
    token,
    target.repo,
    target.branch,
    path,
    content: content,
    message: message,
    sha: expectedSha,
  );
}
