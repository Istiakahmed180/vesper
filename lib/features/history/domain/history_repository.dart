import 'history_models.dart';

abstract class HistoryRepository {
  Stream<List<HistoryEntry>> watch({int limit = 500});
  Future<void> add(HistoryEntry entry);
  Future<HistoryEntry?> get(String id);
  Future<void> delete(String id);
  Future<void> clear();

  /// Removes entries older than [retentionDays] (0 = keep) and beyond [maxEntries].
  Future<int> prune({required int retentionDays, required int maxEntries});
}
