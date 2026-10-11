import 'cloud_models.dart';

/// Two-way, offline-first sync between the local database and the cloud.
///
/// Local edits are recorded in an outbox (by database triggers) and pushed;
/// cloud changes are pulled after a cursor per space (the personal space and
/// each shared workspace). Conflicts resolve by last write wins: a pulled
/// item is skipped when the device changed it later, and the cloud ignores
/// uploads older than what it stores.
class SyncEngine {
  SyncEngine({required this.local, required this.cloud});

  final LocalSyncStore local;
  final CloudStore cloud;

  /// Pulled changes overlap the cursor by this much, so items committed out
  /// of order on the server are not missed. Applying an item twice is safe.
  static const cursorOverlap = Duration(seconds: 5);

  /// Refreshes shared-workspace memberships (accepting invites); workspaces
  /// the user left or was removed from disappear locally.
  Future<Map<String, WorkspaceRole>> refreshMemberships() async {
    final memberships = await cloud.memberships();
    await local.writeMemberships(memberships);
    return memberships;
  }

  Future<int> pull({Iterable<String> sharedWorkspaces = const []}) async {
    var count = 0;
    for (final scope in [null, ...sharedWorkspaces]) {
      count += await _pullScope(scope);
    }
    return count;
  }

  Future<int> _pullScope(String? scope) async {
    final cursor = await local.readCursor(scope: scope);
    final items = await cloud.changesSince(
      cursor?.subtract(cursorOverlap),
      scope: scope,
    );
    if (items.isEmpty) return 0;
    await local.apply(items);
    final newest = items
        .map((i) => i.serverUpdatedAt)
        .whereType<DateTime>()
        .fold<DateTime?>(
          cursor,
          (max, t) => max == null || t.isAfter(max) ? t : max,
        );
    if (newest != null) await local.writeCursor(newest, scope: scope);
    return items.length;
  }

  Future<int> push() async {
    var pushed = 0;
    while (true) {
      final entries = await local.pending();
      if (entries.isEmpty) return pushed;
      final items = [for (final e in entries) ...await local.snapshot(e)];
      await cloud.upsert(items);
      await local.acknowledge(entries, items);
      pushed += entries.length;
      if (entries.length < 500) return pushed;
    }
  }

  /// Memberships first (so items are filed in the right space), then pull
  /// so a fresh device adopts cloud data before uploading.
  Future<({int pulled, int pushed})> sync() async {
    final memberships = await refreshMemberships();
    final pulled = await pull(sharedWorkspaces: memberships.keys);
    final pushed = await push();
    return (pulled: pulled, pushed: pushed);
  }
}
