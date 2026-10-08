import 'package:drift/drift.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/security/secret_vault.dart';
import '../../../core/storage/app_database.dart';
import '../../../core/utils/id.dart';
import '../../api_client/domain/models/api_request.dart';
import '../domain/collection_models.dart';
import '../domain/collection_repository.dart';
import 'request_row_mapper.dart';

class DriftCollectionRepository implements CollectionRepository {
  DriftCollectionRepository(this._db, this._vault);

  final AppDatabase _db;
  final SecretVault _vault;
  static const _mapper = RequestRowMapper();

  // ---------------------------------------------------------------- reading

  @override
  // Drift shares stream queries by SQL text (not by tables read), so each
  // change-tick query needs distinct SQL.
  Stream<List<CollectionTree>> watchTrees() => _db
      .customSelect(
        'SELECT 1 AS collections_tick',
        readsFrom: {_db.collections, _db.folders, _db.requests},
      )
      .watch()
      .asyncMap((_) => _loadTrees());

  Future<List<CollectionTree>> _loadTrees() async {
    final cols =
        await (_db.select(_db.collections)..orderBy([
              (c) => OrderingTerm.asc(c.sortOrder),
              (c) => OrderingTerm.asc(c.createdAt),
            ]))
            .get();
    final folderRows = await _db.select(_db.folders).get();
    final requestRows = await _db.select(_db.requests).get();

    final foldersByCollection = <String, List<Folder>>{};
    for (final f in folderRows) {
      foldersByCollection.putIfAbsent(f.collectionId, () => []).add(_folder(f));
    }
    final requestsByCollection = <String, List<ApiRequest>>{};
    for (final r in requestRows) {
      requestsByCollection
          .putIfAbsent(r.collectionId, () => [])
          .add(_mapper.fromRow(r));
    }
    return [
      for (final c in cols)
        CollectionTree.build(
          _collection(c),
          foldersByCollection[c.id] ?? const [],
          requestsByCollection[c.id] ?? const [],
        ),
    ];
  }

  static Collection _collection(CollectionRow c) => Collection(
    id: c.id,
    name: c.name,
    description: c.description,
    sortOrder: c.sortOrder,
    createdAt: c.createdAt,
    updatedAt: c.updatedAt,
  );

  static Folder _folder(FolderRow f) => Folder(
    id: f.id,
    collectionId: f.collectionId,
    parentId: f.parentId,
    name: f.name,
    sortOrder: f.sortOrder,
  );

  @override
  Future<ApiRequest?> getRequest(String id) async {
    final row = await (_db.select(
      _db.requests,
    )..where((r) => r.id.equals(id))).getSingleOrNull();
    if (row == null) return null;
    return _hydrate(_mapper.fromRow(row));
  }

  Future<ApiRequest> _hydrate(ApiRequest request) async {
    final secrets = <String, String>{};
    for (final field in RequestRowMapper.secretFields) {
      final v = await _vault.read(VaultKeys.requestAuth(request.id, field));
      if (v != null) secrets[field] = v;
    }
    return secrets.isEmpty
        ? request
        : request.copyWith(auth: request.auth.withSecrets(secrets));
  }

  Future<void> _writeSecrets(
    String requestId,
    Map<String, String> secrets,
  ) async {
    for (final field in RequestRowMapper.secretFields) {
      final key = VaultKeys.requestAuth(requestId, field);
      final value = secrets[field];
      if (value == null || value.isEmpty) {
        await _vault.delete(key);
      } else {
        await _vault.write(key, value);
      }
    }
  }

  Future<void> _deleteSecrets(Iterable<String> requestIds) async {
    final prefixes = requestIds.map(VaultKeys.requestPrefix).toList();
    if (prefixes.isEmpty) return;
    await _vault.deleteWhere((k) => prefixes.any(k.startsWith));
  }

  // ------------------------------------------------------------ collections

  @override
  Future<Collection> createCollection(
    String name, {
    String description = '',
  }) async {
    final max = await _maxSort(_db.collections, _db.collections.sortOrder);
    final c = Collection(
      name: _nonEmpty(name, 'New collection'),
      description: description,
      sortOrder: max + 1,
    );
    await _db
        .into(_db.collections)
        .insert(
          CollectionsCompanion.insert(
            id: c.id,
            name: c.name,
            description: Value(c.description),
            sortOrder: Value(c.sortOrder),
            createdAt: c.createdAt,
            updatedAt: c.updatedAt,
          ),
        );
    return c;
  }

  @override
  Future<void> updateCollection(
    String id, {
    String? name,
    String? description,
  }) => (_db.update(_db.collections)..where((c) => c.id.equals(id))).write(
    CollectionsCompanion(
      name: name == null
          ? const Value.absent()
          : Value(_nonEmpty(name, 'Untitled')),
      description: description == null
          ? const Value.absent()
          : Value(description),
      updatedAt: Value(DateTime.now()),
    ),
  );

  @override
  Future<void> deleteCollection(String id) async {
    final ids =
        await (_db.selectOnly(_db.requests)
              ..addColumns([_db.requests.id])
              ..where(_db.requests.collectionId.equals(id)))
            .map((r) => r.read(_db.requests.id)!)
            .get();
    await (_db.delete(_db.collections)..where((c) => c.id.equals(id))).go();
    await _deleteSecrets(ids);
  }

  @override
  Future<String> duplicateCollection(String id) async {
    final doc = await exportCollection(id, includeSecrets: true);
    return importCollection(
      CollectionDocument(
        name: '${doc.name} copy',
        description: doc.description,
        items: doc.items,
      ),
    );
  }

  @override
  Future<void> reorderCollection(String id, int newIndex) =>
      _db.transaction(() async {
        final rows =
            await (_db.select(_db.collections)..orderBy([
                  (c) => OrderingTerm.asc(c.sortOrder),
                  (c) => OrderingTerm.asc(c.createdAt),
                ]))
                .get();
        final ids = rows.map((r) => r.id).toList();
        if (!ids.remove(id)) return;
        ids.insert(newIndex.clamp(0, ids.length), id);
        for (var i = 0; i < ids.length; i++) {
          await (_db.update(_db.collections)..where((c) => c.id.equals(ids[i])))
              .write(CollectionsCompanion(sortOrder: Value(i)));
        }
      });

  // ---------------------------------------------------------------- folders

  @override
  Future<Folder> createFolder(
    String collectionId,
    String name, {
    String? parentId,
  }) async {
    final sort = await _nextSortInLocation(
      TreeLocation(collectionId, parentId),
    );
    final f = Folder(
      collectionId: collectionId,
      parentId: parentId,
      name: _nonEmpty(name, 'New folder'),
      sortOrder: sort,
    );
    final now = DateTime.now();
    await _db
        .into(_db.folders)
        .insert(
          FoldersCompanion.insert(
            id: f.id,
            collectionId: collectionId,
            parentId: Value(parentId),
            name: f.name,
            sortOrder: Value(sort),
            createdAt: now,
            updatedAt: now,
          ),
        );
    await _touchCollection(collectionId);
    return f;
  }

  @override
  Future<void> renameFolder(String id, String name) =>
      (_db.update(_db.folders)..where((f) => f.id.equals(id))).write(
        FoldersCompanion(
          name: Value(_nonEmpty(name, 'Untitled folder')),
          updatedAt: Value(DateTime.now()),
        ),
      );

  Future<Set<String>> _folderSubtree(String folderId) async {
    final all = await _db.select(_db.folders).get();
    final result = <String>{folderId};
    var changed = true;
    while (changed) {
      changed = false;
      for (final f in all) {
        if (f.parentId != null &&
            result.contains(f.parentId) &&
            result.add(f.id)) {
          changed = true;
        }
      }
    }
    return result;
  }

  @override
  Future<void> deleteFolder(String id) async {
    final subtree = await _folderSubtree(id);
    final ids =
        await (_db.selectOnly(_db.requests)
              ..addColumns([_db.requests.id])
              ..where(_db.requests.folderId.isIn(subtree)))
            .map((r) => r.read(_db.requests.id)!)
            .get();
    await (_db.delete(_db.folders)..where((f) => f.id.equals(id))).go();
    await _deleteSecrets(ids);
  }

  @override
  Future<String> duplicateFolder(String id) async {
    final folder = await (_db.select(
      _db.folders,
    )..where((f) => f.id.equals(id))).getSingleOrNull();
    if (folder == null) {
      throw const StorageFailure('The folder no longer exists.');
    }
    final tree = (await _loadTrees()).firstWhere(
      (t) => t.collection.id == folder.collectionId,
    );
    FolderNode? find(List<TreeNode> nodes) {
      for (final n in nodes) {
        if (n is FolderNode) {
          if (n.id == id) return n;
          final inner = find(n.children);
          if (inner != null) return inner;
        }
      }
      return null;
    }

    final node = find(tree.children);
    if (node == null) {
      throw const StorageFailure('The folder no longer exists.');
    }
    final items = await _itemsFromNodes(node.children, includeSecrets: true);
    late String newId;
    await _db.transaction(() async {
      newId = await _insertFolderItem(
        FolderItem('${folder.name} copy', items),
        collectionId: folder.collectionId,
        parentId: folder.parentId,
        sortOrder: folder.sortOrder + 1,
      );
    });
    return newId;
  }

  @override
  Future<void> moveFolder(
    String id,
    TreeLocation target, {
    int? index,
  }) => _db.transaction(() async {
    final folder = await (_db.select(
      _db.folders,
    )..where((f) => f.id.equals(id))).getSingleOrNull();
    if (folder == null) return;
    final subtree = await _folderSubtree(id);
    if (target.folderId != null && subtree.contains(target.folderId)) {
      throw const ValidationFailure('A folder cannot be moved into itself.');
    }
    await (_db.update(_db.folders)..where((f) => f.id.equals(id))).write(
      FoldersCompanion(
        collectionId: Value(target.collectionId),
        parentId: Value(target.folderId),
        updatedAt: Value(DateTime.now()),
      ),
    );
    if (folder.collectionId != target.collectionId) {
      await (_db.update(_db.folders)..where((f) => f.id.isIn(subtree))).write(
        FoldersCompanion(collectionId: Value(target.collectionId)),
      );
      await (_db.update(_db.requests)..where((r) => r.folderId.isIn(subtree)))
          .write(RequestsCompanion(collectionId: Value(target.collectionId)));
    }
    await _reindex(target, movedId: id, index: index);
  });

  // --------------------------------------------------------------- requests

  @override
  Future<ApiRequest> saveRequest(ApiRequest request) async {
    if (request.collectionId == null) {
      throw const ValidationFailure(
        'Choose a collection to save the request in.',
      );
    }
    final existing = await (_db.select(
      _db.requests,
    )..where((r) => r.id.equals(request.id))).getSingleOrNull();
    var toSave = request.copyWith(updatedAt: DateTime.now());
    if (existing == null) {
      final sort = await _nextSortInLocation(
        TreeLocation(request.collectionId!, request.folderId),
      );
      toSave = toSave.copyWith(sortOrder: sort);
    }
    await _db
        .into(_db.requests)
        .insertOnConflictUpdate(_mapper.toCompanion(toSave));
    await _writeSecrets(toSave.id, toSave.auth.secrets);
    await _touchCollection(toSave.collectionId!);
    return toSave;
  }

  @override
  Future<void> renameRequest(String id, String name) =>
      (_db.update(_db.requests)..where((r) => r.id.equals(id))).write(
        RequestsCompanion(
          name: Value(_nonEmpty(name, 'Untitled request')),
          updatedAt: Value(DateTime.now()),
        ),
      );

  @override
  Future<void> deleteRequest(String id) async {
    await (_db.delete(_db.requests)..where((r) => r.id.equals(id))).go();
    await _deleteSecrets([id]);
  }

  @override
  Future<ApiRequest> duplicateRequest(String id) async {
    final original = await getRequest(id);
    if (original == null) {
      throw const StorageFailure('The request no longer exists.');
    }
    final copy = original.copyWith(
      id: newId(),
      name: '${original.name} copy',
      createdAt: DateTime.now(),
      sortOrder: original.sortOrder,
    );
    final saved = await saveRequest(copy);
    await _reindex(
      TreeLocation(original.collectionId!, original.folderId),
      movedId: saved.id,
      afterId: original.id,
    );
    return saved;
  }

  @override
  Future<void> moveRequest(String id, TreeLocation target, {int? index}) =>
      _db.transaction(() async {
        await (_db.update(_db.requests)..where((r) => r.id.equals(id))).write(
          RequestsCompanion(
            collectionId: Value(target.collectionId),
            folderId: Value(target.folderId),
            updatedAt: Value(DateTime.now()),
          ),
        );
        await _reindex(target, movedId: id, index: index);
      });

  // ------------------------------------------------------- import / export

  @override
  Future<CollectionDocument> exportCollection(
    String id, {
    bool includeSecrets = false,
  }) async {
    final tree = (await _loadTrees())
        .where((t) => t.collection.id == id)
        .firstOrNull;
    if (tree == null) {
      throw const StorageFailure('The collection no longer exists.');
    }
    return CollectionDocument(
      name: tree.collection.name,
      description: tree.collection.description,
      items: await _itemsFromNodes(
        tree.children,
        includeSecrets: includeSecrets,
      ),
    );
  }

  Future<List<CollectionItem>> _itemsFromNodes(
    List<TreeNode> nodes, {
    required bool includeSecrets,
  }) async {
    final items = <CollectionItem>[];
    for (final node in nodes) {
      switch (node) {
        case FolderNode(:final folder, :final children):
          items.add(
            FolderItem(
              folder.name,
              await _itemsFromNodes(children, includeSecrets: includeSecrets),
            ),
          );
        case RequestNode(:final request):
          items.add(
            RequestItem(includeSecrets ? await _hydrate(request) : request),
          );
      }
    }
    return items;
  }

  @override
  Future<String> importCollection(CollectionDocument document) async {
    final collection = await createCollection(
      document.name,
      description: document.description,
    );
    await _db.transaction(
      () => _insertItems(document.items, collection.id, null),
    );
    return collection.id;
  }

  @override
  Future<void> replaceCollection(String id, CollectionDocument document) async {
    final oldIds =
        await (_db.selectOnly(_db.requests)
              ..addColumns([_db.requests.id])
              ..where(_db.requests.collectionId.equals(id)))
            .map((r) => r.read(_db.requests.id)!)
            .get();
    await _db.transaction(() async {
      await (_db.delete(
        _db.requests,
      )..where((r) => r.collectionId.equals(id))).go();
      await (_db.delete(
        _db.folders,
      )..where((f) => f.collectionId.equals(id))).go();
      await updateCollection(
        id,
        name: document.name,
        description: document.description,
      );
      await _insertItems(document.items, id, null);
    });
    await _deleteSecrets(oldIds);
  }

  Future<void> _insertItems(
    List<CollectionItem> items,
    String collectionId,
    String? folderId,
  ) async {
    var order = 0;
    for (final item in items) {
      switch (item) {
        case FolderItem():
          await _insertFolderItem(
            item,
            collectionId: collectionId,
            parentId: folderId,
            sortOrder: order++,
          );
        case RequestItem(:final request):
          final r = request.copyWith(
            id: newId(),
            collectionId: () => collectionId,
            folderId: () => folderId,
            sortOrder: order++,
            createdAt: DateTime.now(),
          );
          await _db.into(_db.requests).insert(_mapper.toCompanion(r));
          final secrets = r.auth.secrets;
          if (secrets.isNotEmpty) await _writeSecrets(r.id, secrets);
      }
    }
  }

  Future<String> _insertFolderItem(
    FolderItem item, {
    required String collectionId,
    required String? parentId,
    required int sortOrder,
  }) async {
    final id = newId();
    final now = DateTime.now();
    await _db
        .into(_db.folders)
        .insert(
          FoldersCompanion.insert(
            id: id,
            collectionId: collectionId,
            parentId: Value(parentId),
            name: _nonEmpty(item.name, 'Folder'),
            sortOrder: Value(sortOrder),
            createdAt: now,
            updatedAt: now,
          ),
        );
    await _insertItems(item.items, collectionId, id);
    return id;
  }

  // ---------------------------------------------------------------- helpers

  Future<int> _maxSort(
    TableInfo<Table, Object?> table,
    GeneratedColumn<int> column,
  ) async {
    final max = column.max();
    final row = await (_db.selectOnly(table)..addColumns([max])).getSingle();
    return row.read(max) ?? -1;
  }

  Future<int> _nextSortInLocation(TreeLocation loc) async {
    final siblings = await _siblingOrders(loc);
    return siblings.isEmpty ? 0 : siblings.reduce((a, b) => a > b ? a : b) + 1;
  }

  Future<List<int>> _siblingOrders(TreeLocation loc) async {
    final folderQ = _db.select(_db.folders)
      ..where(
        (f) =>
            f.collectionId.equals(loc.collectionId) &
            (loc.folderId == null
                ? f.parentId.isNull()
                : f.parentId.equals(loc.folderId!)),
      );
    final reqQ = _db.select(_db.requests)
      ..where(
        (r) =>
            r.collectionId.equals(loc.collectionId) &
            (loc.folderId == null
                ? r.folderId.isNull()
                : r.folderId.equals(loc.folderId!)),
      );
    return [
      ...(await folderQ.get()).map((f) => f.sortOrder),
      ...(await reqQ.get()).map((r) => r.sortOrder),
    ];
  }

  /// Rewrites sort orders of the children at [loc] so [movedId] ends up at
  /// [index] (or right after [afterId]). Folders and requests share one
  /// ordering space; the tree shows folders first.
  Future<void> _reindex(
    TreeLocation loc, {
    required String movedId,
    int? index,
    String? afterId,
  }) async {
    final folders =
        await (_db.select(_db.folders)..where(
              (f) =>
                  f.collectionId.equals(loc.collectionId) &
                  (loc.folderId == null
                      ? f.parentId.isNull()
                      : f.parentId.equals(loc.folderId!)),
            ))
            .get();
    final requests =
        await (_db.select(_db.requests)..where(
              (r) =>
                  r.collectionId.equals(loc.collectionId) &
                  (loc.folderId == null
                      ? r.folderId.isNull()
                      : r.folderId.equals(loc.folderId!)),
            ))
            .get();
    final movedIsFolder = folders.any((f) => f.id == movedId);
    final group = movedIsFolder
        ? (folders..sort((a, b) => a.sortOrder.compareTo(b.sortOrder)))
              .map((f) => f.id)
              .toList()
        : (requests..sort((a, b) => a.sortOrder.compareTo(b.sortOrder)))
              .map((r) => r.id)
              .toList();
    group.remove(movedId);
    var target = index ?? group.length;
    if (afterId != null) {
      final i = group.indexOf(afterId);
      if (i != -1) target = i + 1;
    }
    group.insert(target.clamp(0, group.length), movedId);
    for (var i = 0; i < group.length; i++) {
      if (movedIsFolder) {
        await (_db.update(_db.folders)..where((f) => f.id.equals(group[i])))
            .write(FoldersCompanion(sortOrder: Value(i)));
      } else {
        await (_db.update(_db.requests)..where((r) => r.id.equals(group[i])))
            .write(RequestsCompanion(sortOrder: Value(i)));
      }
    }
  }

  Future<void> _touchCollection(String id) =>
      (_db.update(_db.collections)..where((c) => c.id.equals(id))).write(
        CollectionsCompanion(updatedAt: Value(DateTime.now())),
      );

  static String _nonEmpty(String value, String fallback) =>
      value.trim().isEmpty ? fallback : value.trim();
}
