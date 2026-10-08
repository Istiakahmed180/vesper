import 'package:flutter/foundation.dart';

import '../../collections/domain/collection_repository.dart';

enum SyncStatus {
  /// Exists locally only; push creates it on the remote.
  newLocal('Not on GitHub'),

  /// Changed locally since the last sync.
  localChanged('Local changes'),

  /// Changed on the remote since the last sync.
  remoteChanged('Changed on GitHub'),

  /// Changed on both sides, or both exist without a common sync base.
  conflict('Conflict'),

  /// The remote file was deleted after the last sync.
  remoteDeleted('Deleted on GitHub'),

  /// Exists only on the remote.
  remoteOnly('Only on GitHub'),

  unchanged('Up to date');

  const SyncStatus(this.label);
  final String label;

  bool get canPush =>
      this == newLocal ||
      this == localChanged ||
      this == conflict ||
      this == remoteDeleted;
  bool get canPull =>
      this == remoteChanged || this == conflict || this == remoteOnly;
  bool get pushOverwritesRemote => this == conflict;
  bool get pullOverwritesLocal => this == conflict || this == remoteChanged;
}

/// One collection's state in a sync plan.
@immutable
class SyncItem {
  const SyncItem({
    required this.path,
    required this.name,
    required this.status,
    this.collectionId,
    this.localContent,
    this.localHash,
    this.localRequestCount,
    this.remoteSha,
    this.remoteDocument,
    this.remoteRequestCount,
    this.lastSyncedAt,
  });

  final String path;
  final String name;
  final SyncStatus status;
  final String? collectionId;
  final String? localContent;
  final String? localHash;
  final int? localRequestCount;
  final String? remoteSha;
  final CollectionDocument? remoteDocument;
  final int? remoteRequestCount;
  final DateTime? lastSyncedAt;
}

@immutable
class SyncPlan {
  const SyncPlan(this.items);
  final List<SyncItem> items;

  bool get hasChanges => items.any((i) => i.status != SyncStatus.unchanged);
}

/// Last synchronised state of an item against a remote.
@immutable
class SyncRecord {
  const SyncRecord({
    required this.itemKey,
    required this.remote,
    required this.path,
    required this.remoteSha,
    required this.contentHash,
    required this.syncedAt,
  });

  final String itemKey;
  final String remote;
  final String path;
  final String remoteSha;
  final String contentHash;
  final DateTime syncedAt;
}

abstract class SyncStateStore {
  Future<List<SyncRecord>> all(String remote);
  Future<void> put(SyncRecord record);
  Future<void> delete(String itemKey, String remote);
}

class RemoteFileData {
  const RemoteFileData({
    required this.path,
    required this.sha,
    required this.content,
  });
  final String path;
  final String sha;
  final String content;
}

/// Storage the sync engine pushes to and pulls from (GitHub today).
abstract class RemoteFileStore {
  String get remoteKey;
  Future<RemoteFileData?> read(String path);
  Future<List<String>> listFiles(String directory);

  /// Writes [content]; [expectedSha] null means "create", otherwise the write
  /// must fail with a conflict if the remote sha differs.
  Future<String> write(
    String path,
    String content, {
    required String message,
    String? expectedSha,
  });
}
