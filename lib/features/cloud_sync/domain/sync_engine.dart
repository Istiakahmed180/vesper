import 'cloud_models.dart';

/// Two-way, offline-first sync between the local database and the cloud.
///
/// Local edits are recorded in an outbox (by database triggers) and pushed;
/// cloud changes are pulled after a cursor. Conflicts resolve by last write
/// wins: a pulled item is skipped when the device changed it later, and the
/// cloud ignores uploads older than what it stores.
class SyncEngine {
  SyncEngine({required this.local, required this.cloud});

  final LocalSyncStore local;
  final CloudStore cloud;

  /// Pulled changes overlap the cursor by this much, so items committed out
  /// of order on the server are not missed. Applying an item twice is safe.
  static const cursorOverlap = Duration(seconds: 5);

  Future<int> pull() async {
    final cursor = await local.readCursor();
    final items = await cloud.changesSince(cursor?.subtract(cursorOverlap));
    if (items.isEmpty) return 0;
    await local.apply(items);
    final newest = items
        .map((i) => i.serverUpdatedAt)
        .whereType<DateTime>()
        .fold<DateTime?>(
          cursor,
          (max, t) => max == null || t.isAfter(max) ? t : max,
        );
    if (newest != null) await local.writeCursor(newest);
    return items.length;
  }

  Future<int> push() async {
    var pushed = 0;
    while (true) {
      final entries = await local.pending();
      if (entries.isEmpty) return pushed;
      final items = [for (final e in entries) await local.snapshot(e)];
      await cloud.upsert(items);
      await local.acknowledge(entries);
      pushed += entries.length;
      if (entries.length < 500) return pushed;
    }
  }

  /// Pull first so a fresh device adopts cloud data before uploading.
  Future<({int pulled, int pushed})> sync() async {
    final pulled = await pull();
    final pushed = await push();
    return (pulled: pulled, pushed: pushed);
  }
}
