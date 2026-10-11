import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/storage/app_database.dart';
import '../../../core/utils/json_read.dart';
import '../../api_client/domain/models/api_request.dart';
import '../domain/history_models.dart';
import '../domain/history_repository.dart';

class DriftHistoryRepository implements HistoryRepository {
  DriftHistoryRepository(
    this._db, {
    this._sanitizer = const HistorySanitizer(),
    this.workspaceId = defaultWorkspaceId,
  });

  final AppDatabase _db;
  final HistorySanitizer _sanitizer;

  /// Entries are recorded in, listed and cleared for this workspace only.
  /// [prune] applies the retention limits to every workspace.
  final String workspaceId;

  @override
  Stream<List<HistoryEntry>> watch({int limit = 500}) =>
      (_db.select(_db.historyEntries)
            ..where((h) => h.workspaceId.equals(workspaceId))
            ..orderBy([(h) => OrderingTerm.desc(h.executedAt)])
            ..limit(limit))
          .watch()
          .map((rows) => rows.map(_fromRow).toList());

  HistoryEntry _fromRow(HistoryRow row) {
    JsonMap json;
    try {
      final decoded = jsonDecode(row.requestJson);
      json = decoded is Map ? decoded.cast<String, Object?>() : {};
    } catch (_) {
      json = {};
    }
    return HistoryEntry(
      id: row.id,
      requestId: row.requestId,
      request: ApiRequest.fromJson(json, keepId: false),
      statusCode: row.statusCode,
      errorMessage: row.errorMessage,
      duration: Duration(milliseconds: row.durationMs),
      sizeBytes: row.sizeBytes,
      executedAt: row.executedAt,
    );
  }

  @override
  Future<void> add(HistoryEntry entry) async {
    final safe = _sanitizer.sanitize(entry.request);
    await _db
        .into(_db.historyEntries)
        .insert(
          HistoryEntriesCompanion.insert(
            id: entry.id,
            workspaceId: Value(workspaceId),
            requestId: Value(entry.requestId),
            method: safe.method.value,
            url: safe.url,
            statusCode: Value(entry.statusCode),
            errorMessage: Value(entry.errorMessage),
            durationMs: Value(entry.duration.inMilliseconds),
            sizeBytes: Value(entry.sizeBytes),
            executedAt: entry.executedAt,
            // Sanitized already, so "includeSecrets" only keeps {{references}}.
            requestJson: jsonEncode(safe.toJson(includeSecrets: true)),
          ),
        );
  }

  @override
  Future<HistoryEntry?> get(String id) async {
    final row = await (_db.select(
      _db.historyEntries,
    )..where((h) => h.id.equals(id))).getSingleOrNull();
    return row == null ? null : _fromRow(row);
  }

  @override
  Future<void> delete(String id) =>
      (_db.delete(_db.historyEntries)..where((h) => h.id.equals(id))).go();

  @override
  Future<void> clear() => (_db.delete(
    _db.historyEntries,
  )..where((h) => h.workspaceId.equals(workspaceId))).go();

  @override
  Future<int> prune({
    required int retentionDays,
    required int maxEntries,
  }) async {
    var removed = 0;
    if (retentionDays > 0) {
      final cutoff = DateTime.now().subtract(Duration(days: retentionDays));
      removed += await (_db.delete(
        _db.historyEntries,
      )..where((h) => h.executedAt.isSmallerThanValue(cutoff))).go();
    }
    final keep =
        await (_db.selectOnly(_db.historyEntries)
              ..addColumns([_db.historyEntries.id])
              ..orderBy([OrderingTerm.desc(_db.historyEntries.executedAt)])
              ..limit(maxEntries))
            .map((r) => r.read(_db.historyEntries.id)!)
            .get();
    removed += await (_db.delete(
      _db.historyEntries,
    )..where((h) => h.id.isNotIn(keep))).go();
    return removed;
  }
}
