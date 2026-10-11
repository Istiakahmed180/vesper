import 'package:flutter/foundation.dart';

import '../../../core/utils/json_read.dart';

/// Synced item types, in the order upserts are applied (parents first).
enum CloudKind {
  workspace,
  collection,
  environment,
  folder,
  request,
  history;

  static CloudKind? parse(String value) =>
      values.where((k) => k.name == value).firstOrNull;
}

/// One synced item as stored in the cloud. [data] is null for deletions.
/// Items never contain secrets.
@immutable
class CloudItem {
  const CloudItem({
    required this.kind,
    required this.id,
    required this.data,
    required this.clientUpdatedAt,
    this.serverUpdatedAt,
  });

  final CloudKind kind;
  final String id;
  final JsonMap? data;
  final DateTime clientUpdatedAt;

  /// Set on items read from the cloud.
  final DateTime? serverUpdatedAt;

  bool get deleted => data == null;

  String get key => '${kind.name}:$id';
}

/// A local change waiting to be uploaded.
@immutable
class OutboxEntry {
  const OutboxEntry(this.kind, this.id, this.changedAt);

  final CloudKind kind;
  final String id;

  /// Raw UTC timestamp as stored; also identifies this version of the entry.
  final String changedAt;

  String get key => '${kind.name}:$id';

  DateTime get time => DateTime.parse(changedAt);
}

/// The cloud side of sync (Supabase in the app, a fake in tests).
abstract class CloudStore {
  /// Stores [items]; the cloud keeps the newest version of each item.
  Future<void> upsert(List<CloudItem> items);

  /// Items stored after [cursor] (all items when null), oldest first.
  Future<List<CloudItem>> changesSince(DateTime? cursor);
}

/// The device side of sync.
abstract class LocalSyncStore {
  Future<List<OutboxEntry>> pending({int limit = 500});

  /// The current local version of an outbox entry, or a deletion.
  Future<CloudItem> snapshot(OutboxEntry entry);

  /// Removes entries that were uploaded and not changed since.
  Future<void> acknowledge(List<OutboxEntry> entries);

  /// Applies cloud items, skipping those with a newer local change.
  Future<void> apply(List<CloudItem> items);

  /// Queues every local item for upload (first sync on this device).
  Future<void> enqueueAll();

  Future<DateTime?> readCursor();
  Future<void> writeCursor(DateTime cursor);
}
