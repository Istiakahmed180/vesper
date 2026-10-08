import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/utils/formatters.dart';
import '../../collections/domain/collection_models.dart';
import '../../collections/domain/collection_repository.dart';
import '../../import_export/domain/collection_codec.dart';
import 'sync_models.dart';

/// Three-way collection sync: compares local content and the remote file
/// against the last synced state to classify each item. It never writes on
/// its own; [push] and [pull] are invoked explicitly per item by the user.
/// Secrets are never included in synced files.
class SyncService {
  SyncService({
    required this.collections,
    required this.states,
    this.codec = const VesperCollectionCodec(),
    this.basePath = 'api-client',
  });

  final CollectionRepository collections;
  final SyncStateStore states;
  final VesperCollectionCodec codec;
  final String basePath;

  String get collectionsDir => '$basePath/collections';

  static String itemKey(String collectionId) => 'collection:$collectionId';

  /// Deterministic file content (no timestamps) so hashes are stable.
  String serialize(CollectionDocument doc) {
    final json = codec.encode(doc)..remove('exportedAt');
    return '${const JsonEncoder.withIndent('  ').convert(json)}\n';
  }

  static String hash(String content) =>
      sha256.convert(utf8.encode(content)).toString();

  CollectionDocument _parseRemote(String content, String path) {
    final Object? json;
    try {
      json = jsonDecode(content);
    } on FormatException {
      throw SyncFailure('"$path" on GitHub is not valid JSON.');
    }
    if (json is! Map) {
      throw SyncFailure('"$path" on GitHub is not a Vesper collection.');
    }
    return codec.parse(json.cast<String, Object?>()).value;
  }

  static int _count(List<CollectionItem> items) => items.fold(
    0,
    (sum, i) =>
        sum +
        switch (i) {
          FolderItem(:final items) => _count(items),
          RequestItem() => 1,
        },
  );

  Future<SyncPlan> plan(
    RemoteFileStore remote,
    List<CollectionTree> trees, {
    Set<String>? only,
  }) async {
    final records = {
      for (final r in await states.all(remote.remoteKey)) r.itemKey: r,
    };
    final items = <SyncItem>[];
    final claimedPaths = <String>{};

    for (final tree in trees) {
      final id = tree.collection.id;
      if (only != null && !only.contains(id)) continue;
      final record = records[itemKey(id)];
      final CollectionDocument doc;
      try {
        doc = await collections.exportCollection(id);
      } on StorageFailure {
        continue; // Deleted while the plan was being built.
      }
      final content = serialize(doc);
      final localHash = hash(content);
      // A never-synced collection must not take over a file that belongs to
      // another (possibly deleted) synced collection.
      final path =
          record?.path ??
          _pathFor(tree.collection, {
            ...claimedPaths,
            ...records.values.map((r) => r.path),
          });
      claimedPaths.add(path);
      final file = await remote.read(path);
      CollectionDocument? remoteDoc;
      String? remoteHash;
      if (file != null) {
        remoteDoc = _parseRemote(file.content, path);
        remoteHash = hash(serialize(remoteDoc));
      }

      final SyncStatus status;
      if (file == null) {
        status = record == null
            ? SyncStatus.newLocal
            : SyncStatus.remoteDeleted;
      } else if (record == null) {
        status = remoteHash == localHash
            ? SyncStatus.unchanged
            : SyncStatus.conflict;
      } else {
        final localChanged = localHash != record.contentHash;
        final remoteChanged =
            file.sha != record.remoteSha && remoteHash != record.contentHash;
        status = switch ((localChanged, remoteChanged)) {
          (true, true) =>
            remoteHash == localHash
                ? SyncStatus.unchanged
                : SyncStatus.conflict,
          (true, false) => SyncStatus.localChanged,
          (false, true) => SyncStatus.remoteChanged,
          (false, false) => SyncStatus.unchanged,
        };
      }

      if (status == SyncStatus.unchanged &&
          file != null &&
          (record == null ||
              record.remoteSha != file.sha ||
              record.contentHash != localHash)) {
        await _record(remote, id, path, file.sha, localHash);
      }

      items.add(
        SyncItem(
          path: path,
          name: tree.collection.name,
          status: status,
          collectionId: id,
          localContent: content,
          localHash: localHash,
          localRequestCount: tree.requestCount,
          remoteSha: file?.sha,
          remoteDocument: remoteDoc,
          remoteRequestCount: remoteDoc == null
              ? null
              : _count(remoteDoc.items),
          lastSyncedAt: record?.syncedAt,
        ),
      );
    }

    if (only == null) {
      // Records of collections deleted locally are stale: their files show up
      // as remote-only again so they can be re-imported.
      final localKeys = {for (final t in trees) itemKey(t.collection.id)};
      for (final r in records.values.where(
        (r) => !localKeys.contains(r.itemKey),
      )) {
        await states.delete(r.itemKey, remote.remoteKey);
      }
      for (final path in await remote.listFiles(collectionsDir)) {
        if (!path.endsWith('.json') || claimedPaths.contains(path)) continue;
        final file = await remote.read(path);
        if (file == null) continue;
        try {
          final doc = _parseRemote(file.content, path);
          items.add(
            SyncItem(
              path: path,
              name: doc.name,
              status: SyncStatus.remoteOnly,
              remoteSha: file.sha,
              remoteDocument: doc,
              remoteRequestCount: _count(doc.items),
            ),
          );
        } on AppFailure {
          // Non-Vesper JSON files in the folder are ignored.
        }
      }
    }
    return SyncPlan(items);
  }

  String _pathFor(Collection c, Set<String> taken) {
    final base = '$collectionsDir/${Formatters.slug(c.name)}';
    var path = '$base.json';
    if (taken.contains(path)) path = '$base-${c.id.substring(0, 8)}.json';
    return path;
  }

  /// Uploads the local collection. For conflicts [overwrite] must be true,
  /// in which case the current remote sha is used as the precondition.
  Future<void> push(
    RemoteFileStore remote,
    SyncItem item, {
    bool overwrite = false,
  }) async {
    final id = item.collectionId;
    final content = item.localContent;
    if (id == null || content == null) {
      throw const SyncFailure('Nothing to push for this item.');
    }
    if (item.status == SyncStatus.conflict && !overwrite) {
      throw const SyncFailure(
        'This collection has conflicting changes. Choose which version to keep.',
      );
    }
    final sha = await remote.write(
      item.path,
      content,
      message:
          'Vesper: ${item.status == SyncStatus.newLocal ? 'add' : 'update'} ${item.name}',
      expectedSha: item.remoteSha,
    );
    await _record(remote, id, item.path, sha, item.localHash!);
  }

  /// Replaces the local collection with the remote version (or imports a
  /// remote-only collection as a new one).
  Future<String> pull(RemoteFileStore remote, SyncItem item) async {
    final doc = item.remoteDocument;
    final sha = item.remoteSha;
    if (doc == null || sha == null) {
      throw const SyncFailure('Nothing to pull for this item.');
    }
    final String id;
    if (item.collectionId == null) {
      id = await collections.importCollection(doc);
    } else {
      id = item.collectionId!;
      await collections.replaceCollection(id, doc);
    }
    final localHash = hash(serialize(await collections.exportCollection(id)));
    await _record(remote, id, item.path, sha, localHash);
    return id;
  }

  Future<void> _record(
    RemoteFileStore remote,
    String id,
    String path,
    String sha,
    String contentHash,
  ) => states.put(
    SyncRecord(
      itemKey: itemKey(id),
      remote: remote.remoteKey,
      path: path,
      remoteSha: sha,
      contentHash: contentHash,
      syncedAt: DateTime.now(),
    ),
  );
}
