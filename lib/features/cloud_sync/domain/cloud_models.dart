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
    this.scope,
  });

  final CloudKind kind;
  final String id;
  final JsonMap? data;
  final DateTime clientUpdatedAt;

  /// The shared workspace the item is stored in, or null for the user's
  /// personal space.
  final String? scope;

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

/// Role in a shared workspace.
enum WorkspaceRole { owner, member }

@immutable
class WorkspaceMember {
  const WorkspaceMember({
    required this.userId,
    required this.email,
    required this.role,
  });

  final String userId;
  final String email;
  final WorkspaceRole role;
}

/// The cloud side of sync (Supabase in the app, a fake in tests).
abstract class CloudStore {
  /// Stores [items], each in its [CloudItem.scope]; the cloud keeps the
  /// newest version of each item.
  Future<void> upsert(List<CloudItem> items);

  /// Items of [scope] (personal when null) stored after [cursor] (all items
  /// when null), oldest first.
  Future<List<CloudItem>> changesSince(DateTime? cursor, {String? scope});

  /// Accepts pending invites for this user, then lists the shared
  /// workspaces they belong to.
  Future<Map<String, WorkspaceRole>> memberships();
}

/// The device side of sync.
abstract class LocalSyncStore {
  Future<List<OutboxEntry>> pending({int limit = 500});

  /// The current local version of an outbox entry (or a deletion), in the
  /// space it belongs to now. When it moved between spaces a deletion for the
  /// old space is included.
  Future<List<CloudItem>> snapshot(OutboxEntry entry);

  /// Removes entries that were uploaded and not changed since, and records
  /// where [uploaded] items now live.
  Future<void> acknowledge(List<OutboxEntry> entries, List<CloudItem> uploaded);

  /// Applies cloud items of one space, skipping those with a newer local
  /// change.
  Future<void> apply(List<CloudItem> items);

  /// Queues every local item for upload (first sync on this device).
  Future<void> enqueueAll();

  Future<DateTime?> readCursor({String? scope});
  Future<void> writeCursor(DateTime cursor, {String? scope});

  /// Shared workspaces known from the last sync.
  Future<Map<String, WorkspaceRole>> readMemberships();

  /// Stores [memberships]; workspaces the user no longer belongs to are
  /// removed from this computer.
  Future<void> writeMemberships(Map<String, WorkspaceRole> memberships);
}
