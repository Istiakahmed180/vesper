import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/security/secret_vault.dart';
import '../../../core/storage/app_database.dart';
import '../../../core/utils/json_read.dart';
import '../../collections/data/request_row_mapper.dart';
import '../domain/cloud_models.dart';

/// [LocalSyncStore] on the Drift database. Rows already contain no secrets
/// (those live in the vault), so they are synced as they are.
class DriftLocalSyncStore implements LocalSyncStore {
  DriftLocalSyncStore(this._db, this._vault);

  final AppDatabase _db;
  final SecretVault _vault;

  static const cursorKey = 'cloud.cursor';

  // ------------------------------------------------------------------ outbox

  @override
  Future<List<OutboxEntry>> pending({int limit = 500}) async {
    final rows =
        await (_db.select(_db.syncOutbox)
              ..orderBy([(o) => OrderingTerm.asc(o.changedAt)])
              ..limit(limit))
            .get();
    final entries = <OutboxEntry>[];
    for (final row in rows) {
      final kind = CloudKind.parse(row.kind);
      if (kind == null) {
        await _deleteOutbox(row.kind, row.itemId);
      } else {
        entries.add(OutboxEntry(kind, row.itemId, row.changedAt));
      }
    }
    return entries;
  }

  @override
  Future<void> acknowledge(List<OutboxEntry> entries) =>
      _db.transaction(() async {
        for (final e in entries) {
          await (_db.delete(_db.syncOutbox)..where(
                (o) =>
                    o.kind.equals(e.kind.name) &
                    o.itemId.equals(e.id) &
                    o.changedAt.equals(e.changedAt),
              ))
              .go();
        }
      });

  Future<void> _deleteOutbox(String kind, String id) => (_db.delete(
    _db.syncOutbox,
  )..where((o) => o.kind.equals(kind) & o.itemId.equals(id))).go();

  @override
  Future<CloudItem> snapshot(OutboxEntry entry) async => CloudItem(
    kind: entry.kind,
    id: entry.id,
    data: await _serialize(entry.kind, entry.id),
    clientUpdatedAt: entry.time,
  );

  @override
  Future<void> enqueueAll() async {
    final entries = <(CloudKind, String, DateTime)>[];
    for (final w in await _db.select(_db.workspaces).get()) {
      // An untouched default workspace has nothing to contribute.
      if (w.id == defaultWorkspaceId && w.name == defaultWorkspaceName) {
        continue;
      }
      entries.add((CloudKind.workspace, w.id, w.updatedAt));
    }
    for (final c in await _db.select(_db.collections).get()) {
      entries.add((CloudKind.collection, c.id, c.updatedAt));
    }
    for (final f in await _db.select(_db.folders).get()) {
      entries.add((CloudKind.folder, f.id, f.updatedAt));
    }
    for (final r in await _db.select(_db.requests).get()) {
      entries.add((CloudKind.request, r.id, r.updatedAt));
    }
    final withVariables = {
      for (final v in await _db.select(_db.envVariables).get()) v.environmentId,
    };
    for (final e in await _db.select(_db.environments).get()) {
      // Empty Globals are created on every device; skip them.
      if (e.isGlobal && !withVariables.contains(e.id)) continue;
      entries.add((CloudKind.environment, e.id, e.updatedAt));
    }
    for (final h in await _db.select(_db.historyEntries).get()) {
      entries.add((CloudKind.history, h.id, h.executedAt));
    }
    await _db.batch((b) {
      for (final (kind, id, time) in entries) {
        b.insert(
          _db.syncOutbox,
          SyncOutboxCompanion.insert(
            kind: kind.name,
            itemId: id,
            changedAt: _iso(time),
          ),
          mode: InsertMode.insertOrIgnore,
        );
      }
    });
  }

  @override
  Future<DateTime?> readCursor() async {
    final row = await (_db.select(
      _db.settingsEntries,
    )..where((s) => s.key.equals(cursorKey))).getSingleOrNull();
    return row == null ? null : DateTime.tryParse(row.value);
  }

  @override
  Future<void> writeCursor(DateTime cursor) => _db
      .into(_db.settingsEntries)
      .insertOnConflictUpdate(
        SettingsEntriesCompanion.insert(key: cursorKey, value: _iso(cursor)),
      );

  /// Forgets the cursor and pending changes (sign-out of another account).
  Future<void> reset() async {
    await _db.delete(_db.syncOutbox).go();
    await (_db.delete(
      _db.settingsEntries,
    )..where((s) => s.key.equals(cursorKey))).go();
  }

  // ------------------------------------------------------------ serializing

  static String _iso(DateTime t) => t.toUtc().toIso8601String();
  static DateTime _date(JsonMap d, String key) =>
      DateTime.tryParse(d.str(key))?.toLocal() ?? DateTime.now();

  Future<JsonMap?> _serialize(CloudKind kind, String id) async {
    switch (kind) {
      case CloudKind.workspace:
        final w = await (_db.select(
          _db.workspaces,
        )..where((t) => t.id.equals(id))).getSingleOrNull();
        return w == null
            ? null
            : {
                'name': w.name,
                'sortOrder': w.sortOrder,
                'createdAt': _iso(w.createdAt),
                'updatedAt': _iso(w.updatedAt),
              };
      case CloudKind.collection:
        final c = await (_db.select(
          _db.collections,
        )..where((t) => t.id.equals(id))).getSingleOrNull();
        return c == null
            ? null
            : {
                'workspaceId': c.workspaceId,
                'name': c.name,
                'description': c.description,
                'auth': RequestRowMapper.decodeMap(c.authJson),
                'variables': RequestRowMapper.decodeList(c.variablesJson),
                'sortOrder': c.sortOrder,
                'createdAt': _iso(c.createdAt),
                'updatedAt': _iso(c.updatedAt),
              };
      case CloudKind.folder:
        final f = await (_db.select(
          _db.folders,
        )..where((t) => t.id.equals(id))).getSingleOrNull();
        return f == null
            ? null
            : {
                'collectionId': f.collectionId,
                'parentId': f.parentId,
                'name': f.name,
                'sortOrder': f.sortOrder,
                'createdAt': _iso(f.createdAt),
                'updatedAt': _iso(f.updatedAt),
              };
      case CloudKind.request:
        final r = await (_db.select(
          _db.requests,
        )..where((t) => t.id.equals(id))).getSingleOrNull();
        return r == null
            ? null
            : {
                'collectionId': r.collectionId,
                'folderId': r.folderId,
                'name': r.name,
                'method': r.method,
                'url': r.url,
                'params': RequestRowMapper.decodeList(r.paramsJson),
                'headers': RequestRowMapper.decodeList(r.headersJson),
                'body': RequestRowMapper.decodeMap(r.bodyJson),
                'auth': RequestRowMapper.decodeMap(r.authJson),
                'options': RequestRowMapper.decodeMap(r.optionsJson),
                'description': r.description,
                'sortOrder': r.sortOrder,
                'createdAt': _iso(r.createdAt),
                'updatedAt': _iso(r.updatedAt),
              };
      case CloudKind.environment:
        final e = await (_db.select(
          _db.environments,
        )..where((t) => t.id.equals(id))).getSingleOrNull();
        if (e == null) return null;
        final vars =
            await (_db.select(_db.envVariables)
                  ..where((v) => v.environmentId.equals(id))
                  ..orderBy([(v) => OrderingTerm.asc(v.sortOrder)]))
                .get();
        return {
          'workspaceId': e.workspaceId,
          'name': e.name,
          'isGlobal': e.isGlobal,
          'sortOrder': e.sortOrder,
          'createdAt': _iso(e.createdAt),
          'updatedAt': _iso(e.updatedAt),
          'variables': [
            for (final v in vars)
              {
                'id': v.id,
                'key': v.key,
                // Secret values are empty in the database already.
                'value': v.isSecret ? '' : v.value,
                'enabled': v.enabled,
                'secret': v.isSecret,
              },
          ],
        };
      case CloudKind.history:
        final h = await (_db.select(
          _db.historyEntries,
        )..where((t) => t.id.equals(id))).getSingleOrNull();
        return h == null
            ? null
            : {
                'workspaceId': h.workspaceId,
                'requestId': h.requestId,
                'method': h.method,
                'url': h.url,
                'statusCode': h.statusCode,
                'errorMessage': h.errorMessage,
                'durationMs': h.durationMs,
                'sizeBytes': h.sizeBytes,
                'executedAt': _iso(h.executedAt),
                'request': RequestRowMapper.decodeMap(h.requestJson),
              };
    }
  }

  // ---------------------------------------------------------------- applying

  @override
  Future<void> apply(List<CloudItem> items) async {
    // Newest version of each item.
    final sorted = [...items]
      ..sort(
        (a, b) => (a.serverUpdatedAt ?? a.clientUpdatedAt).compareTo(
          b.serverUpdatedAt ?? b.clientUpdatedAt,
        ),
      );
    final latest = {for (final i in sorted) i.key: i};
    final outbox = {
      for (final o in await _db.select(_db.syncOutbox).get())
        '${o.kind}:${o.itemId}': DateTime.tryParse(o.changedAt),
    };
    // Last write wins: a newer local change is kept and uploaded later.
    final accepted = [
      for (final item in latest.values)
        if (outbox[item.key] case final local
            when local == null || !local.isAfter(item.clientUpdatedAt))
          item,
    ];
    if (accepted.isEmpty) return;

    final batchIds = {
      for (final kind in CloudKind.values)
        kind: {
          for (final i in accepted)
            if (i.kind == kind && !i.deleted) i.id,
        },
    };
    var removedAny = false;

    await _db.withoutChangeTracking(() async {
      await _db.customStatement('PRAGMA defer_foreign_keys = ON');
      for (final kind in CloudKind.values) {
        for (final item in accepted.where((i) => i.kind == kind)) {
          if (!item.deleted) await _upsert(item, batchIds);
        }
      }
      for (final kind in CloudKind.values.reversed) {
        for (final item in accepted.where((i) => i.kind == kind)) {
          if (item.deleted) removedAny |= await _remove(item);
        }
      }
      for (final item in accepted) {
        await (_db.delete(_db.syncOutbox)..where(
              (o) =>
                  o.kind.equals(item.kind.name) &
                  o.itemId.equals(item.id) &
                  o.changedAt.isSmallerOrEqualValue(_iso(item.clientUpdatedAt)),
            ))
            .go();
      }
    });
    if (removedAny) await _removeOrphanedSecrets();
  }

  Future<bool> _exists(TableInfo<Table, Object?> table, String id) async {
    final rows = await _db
        .customSelect(
          'SELECT 1 FROM ${table.actualTableName} WHERE id = ? LIMIT 1',
          variables: [Variable.withString(id)],
        )
        .get();
    return rows.isNotEmpty;
  }

  Future<void> _upsert(
    CloudItem item,
    Map<CloudKind, Set<String>> batchIds,
  ) async {
    final d = item.data!;
    switch (item.kind) {
      case CloudKind.workspace:
        await _db
            .into(_db.workspaces)
            .insert(
              WorkspacesCompanion.insert(
                id: item.id,
                name: d.str('name', 'Workspace'),
                sortOrder: Value(d.integer('sortOrder')),
                createdAt: _date(d, 'createdAt'),
                updatedAt: _date(d, 'updatedAt'),
              ),
              // The selected environment stays a per-device choice.
              onConflict: DoUpdate(
                (_) => WorkspacesCompanion(
                  name: Value(d.str('name', 'Workspace')),
                  sortOrder: Value(d.integer('sortOrder')),
                  updatedAt: Value(_date(d, 'updatedAt')),
                ),
              ),
            );
      case CloudKind.collection:
        await _db
            .into(_db.collections)
            .insertOnConflictUpdate(
              CollectionsCompanion.insert(
                id: item.id,
                workspaceId: Value(d.str('workspaceId', defaultWorkspaceId)),
                name: d.str('name', 'Collection'),
                description: Value(d.str('description')),
                authJson: Value(jsonEncode(d.obj('auth'))),
                variablesJson: Value(jsonEncode(d.objList('variables'))),
                sortOrder: Value(d.integer('sortOrder')),
                createdAt: _date(d, 'createdAt'),
                updatedAt: _date(d, 'updatedAt'),
              ),
            );
      case CloudKind.folder:
        final collectionId = d.str('collectionId');
        final parentId = d.strOrNull('parentId');
        if (!await _exists(_db.collections, collectionId) ||
            (parentId != null &&
                !batchIds[CloudKind.folder]!.contains(parentId) &&
                !await _exists(_db.folders, parentId))) {
          return; // Orphan: its parent was deleted.
        }
        await _db
            .into(_db.folders)
            .insertOnConflictUpdate(
              FoldersCompanion.insert(
                id: item.id,
                collectionId: collectionId,
                parentId: Value(parentId),
                name: d.str('name', 'Folder'),
                sortOrder: Value(d.integer('sortOrder')),
                createdAt: _date(d, 'createdAt'),
                updatedAt: _date(d, 'updatedAt'),
              ),
            );
      case CloudKind.request:
        final collectionId = d.str('collectionId');
        final folderId = d.strOrNull('folderId');
        if (!await _exists(_db.collections, collectionId) ||
            (folderId != null && !await _exists(_db.folders, folderId))) {
          return;
        }
        await _db
            .into(_db.requests)
            .insertOnConflictUpdate(
              RequestsCompanion.insert(
                id: item.id,
                collectionId: collectionId,
                folderId: Value(folderId),
                name: d.str('name', 'Request'),
                method: d.str('method', 'GET'),
                url: d.str('url'),
                paramsJson: Value(jsonEncode(d.objList('params'))),
                headersJson: Value(jsonEncode(d.objList('headers'))),
                bodyJson: Value(jsonEncode(d.obj('body'))),
                authJson: Value(jsonEncode(d.obj('auth'))),
                optionsJson: Value(jsonEncode(d.obj('options'))),
                description: Value(d.str('description')),
                sortOrder: Value(d.integer('sortOrder')),
                createdAt: _date(d, 'createdAt'),
                updatedAt: _date(d, 'updatedAt'),
              ),
            );
      case CloudKind.environment:
        await _db
            .into(_db.environments)
            .insertOnConflictUpdate(
              EnvironmentsCompanion.insert(
                id: item.id,
                workspaceId: Value(d.str('workspaceId', defaultWorkspaceId)),
                name: d.str('name', 'Environment'),
                isGlobal: Value(d.boolean('isGlobal')),
                sortOrder: Value(d.integer('sortOrder')),
                createdAt: _date(d, 'createdAt'),
                updatedAt: _date(d, 'updatedAt'),
              ),
            );
        await (_db.delete(
          _db.envVariables,
        )..where((v) => v.environmentId.equals(item.id))).go();
        var order = 0;
        for (final v in d.objList('variables')) {
          final isSecret = v.boolean('secret');
          await _db
              .into(_db.envVariables)
              .insertOnConflictUpdate(
                EnvVariablesCompanion.insert(
                  id: v.str('id').isEmpty ? '${item.id}-$order' : v.str('id'),
                  environmentId: item.id,
                  key: v.str('key'),
                  // Secret values stay in this device's vault.
                  value: Value(isSecret ? '' : v.str('value')),
                  enabled: Value(v.boolean('enabled', true)),
                  isSecret: Value(isSecret),
                  sortOrder: Value(order++),
                ),
              );
        }
      case CloudKind.history:
        await _db
            .into(_db.historyEntries)
            .insertOnConflictUpdate(
              HistoryEntriesCompanion.insert(
                id: item.id,
                workspaceId: Value(d.str('workspaceId', defaultWorkspaceId)),
                requestId: Value(d.strOrNull('requestId')),
                method: d.str('method', 'GET'),
                url: d.str('url'),
                statusCode: Value(d.intOrNull('statusCode')),
                errorMessage: Value(d.strOrNull('errorMessage')),
                durationMs: Value(d.integer('durationMs')),
                sizeBytes: Value(d.integer('sizeBytes')),
                executedAt: _date(d, 'executedAt'),
                requestJson: jsonEncode(d.obj('request')),
              ),
            );
    }
  }

  /// Returns whether anything was deleted.
  Future<bool> _remove(CloudItem item) async {
    final TableInfo<Table, Object?> table = switch (item.kind) {
      CloudKind.workspace => _db.workspaces,
      CloudKind.collection => _db.collections,
      CloudKind.folder => _db.folders,
      CloudKind.request => _db.requests,
      CloudKind.environment => _db.environments,
      CloudKind.history => _db.historyEntries,
    };
    // The default workspace exists on every device.
    if (item.kind == CloudKind.workspace && item.id == defaultWorkspaceId) {
      return false;
    }
    final count = await _db.customUpdate(
      'DELETE FROM ${table.actualTableName} WHERE id = ?',
      variables: [Variable.withString(item.id)],
      updates: {table},
      updateKind: UpdateKind.delete,
    );
    return count > 0;
  }

  /// Deletes vault secrets of requests, collections and environments that
  /// no longer exist after applying cloud deletions.
  Future<void> _removeOrphanedSecrets() async {
    final requests = {
      for (final r in await _db.select(_db.requests).get()) r.id,
    };
    final collections = {
      for (final c in await _db.select(_db.collections).get()) c.id,
    };
    final environments = {
      for (final e in await _db.select(_db.environments).get()) e.id,
    };
    final pattern = RegExp(
      '^${RegExp.escape(VaultKeys.prefix)}(request|collection|env)\\.([^.]+)\\.',
    );
    await _vault.deleteWhere((key) {
      final m = pattern.firstMatch(key);
      if (m == null) return false;
      final id = m.group(2)!;
      return switch (m.group(1)) {
        'request' => !requests.contains(id),
        'collection' => !collections.contains(id),
        _ => !environments.contains(id),
      };
    });
  }
}
