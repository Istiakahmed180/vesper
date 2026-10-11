import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import '../../../core/utils/id.dart';
import '../../api_client/domain/models/api_request.dart';
import '../../api_client/domain/models/request_auth.dart';
import '../../api_client/domain/services/variable_resolver.dart';
import '../../environments/domain/environment_models.dart';

@immutable
class Collection {
  Collection({
    String? id,
    required this.name,
    this.description = '',
    this.sortOrder = 0,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : id = id ?? newId(),
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? createdAt ?? DateTime.now();

  final String id;
  final String name;
  final String description;
  final int sortOrder;
  final DateTime createdAt;
  final DateTime updatedAt;

  Collection copyWith({
    String? name,
    String? description,
    int? sortOrder,
    DateTime? updatedAt,
  }) => Collection(
    id: id,
    name: name ?? this.name,
    description: description ?? this.description,
    sortOrder: sortOrder ?? this.sortOrder,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

/// Authorization and variables shared by every request in a collection.
/// Requests use [auth] when set to "Inherit auth from parent"; [variables]
/// rank between the active environment and the Globals.
@immutable
class CollectionSettings {
  const CollectionSettings({
    this.auth = const NoAuth(),
    this.variables = const [],
  });

  /// Never [InheritAuth]: a collection has no parent.
  final RequestAuth auth;
  final List<EnvVariable> variables;

  bool get isEmpty =>
      auth is NoAuth && variables.every((v) => v.key.trim().isEmpty);

  CollectionSettings copyWith({
    RequestAuth? auth,
    List<EnvVariable>? variables,
  }) => CollectionSettings(
    auth: auth ?? this.auth,
    variables: variables ?? this.variables,
  );

  Map<String, VariableValue> toScope() => {
    for (final v in variables)
      if (v.isActive)
        v.key.trim(): VariableValue(
          v.value,
          VariableSource.collection,
          isSecret: v.isSecret,
        ),
  };

  static const _eq = ListEquality<EnvVariable>();

  @override
  bool operator ==(Object other) =>
      other is CollectionSettings &&
      other.auth == auth &&
      _eq.equals(other.variables, variables);

  @override
  int get hashCode => Object.hash(auth, _eq.hash(variables));
}

@immutable
class Folder {
  Folder({
    String? id,
    required this.collectionId,
    this.parentId,
    required this.name,
    this.sortOrder = 0,
  }) : id = id ?? newId();

  final String id;
  final String collectionId;
  final String? parentId;
  final String name;
  final int sortOrder;
}

/// A node in a collection tree. Folders contain children; requests are leaves.
@immutable
sealed class TreeNode {
  const TreeNode();
  String get id;
  String get name;
  int get sortOrder;
}

class FolderNode extends TreeNode {
  const FolderNode(this.folder, this.children);

  final Folder folder;
  final List<TreeNode> children;

  @override
  String get id => folder.id;
  @override
  String get name => folder.name;
  @override
  int get sortOrder => folder.sortOrder;

  int get requestCount => children.fold(
    0,
    (sum, c) =>
        sum +
        switch (c) {
          final FolderNode f => f.requestCount,
          RequestNode() => 1,
        },
  );
}

class RequestNode extends TreeNode {
  const RequestNode(this.request);

  final ApiRequest request;

  @override
  String get id => request.id;
  @override
  String get name => request.name;
  @override
  int get sortOrder => request.sortOrder;
}

@immutable
class CollectionTree {
  const CollectionTree(this.collection, this.children);

  final Collection collection;

  /// Top-level folders and requests, folders first, each in sort order.
  final List<TreeNode> children;

  int get requestCount => children.fold(
    0,
    (sum, c) =>
        sum +
        switch (c) {
          final FolderNode f => f.requestCount,
          RequestNode() => 1,
        },
  );

  /// Builds a tree from flat rows.
  static CollectionTree build(
    Collection collection,
    List<Folder> folderRows,
    List<ApiRequest> requestRows,
  ) {
    // Orphans (parent no longer exists) are attached to the root.
    final folderIds = folderRows.map((f) => f.id).toSet();
    final folders = [
      for (final f in folderRows)
        f.parentId != null && !folderIds.contains(f.parentId)
            ? Folder(
                id: f.id,
                collectionId: f.collectionId,
                name: f.name,
                sortOrder: f.sortOrder,
              )
            : f,
    ];
    final requests = [
      for (final r in requestRows)
        r.folderId != null && !folderIds.contains(r.folderId)
            ? r.copyWith(folderId: () => null)
            : r,
    ];

    List<TreeNode> childrenOf(String? folderId, Set<String> visiting) {
      final subFolders =
          folders
              .where((f) => f.parentId == folderId && !visiting.contains(f.id))
              .toList()
            ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
      final reqs = requests.where((r) => r.folderId == folderId).toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
      return [
        for (final f in subFolders)
          FolderNode(f, childrenOf(f.id, {...visiting, f.id})),
        for (final r in reqs) RequestNode(r),
      ];
    }

    return CollectionTree(collection, childrenOf(null, const {}));
  }

  Iterable<ApiRequest> get allRequests sync* {
    Iterable<ApiRequest> walk(List<TreeNode> nodes) sync* {
      for (final n in nodes) {
        switch (n) {
          case FolderNode(:final children):
            yield* walk(children);
          case RequestNode(:final request):
            yield request;
        }
      }
    }

    yield* walk(children);
  }

  Iterable<Folder> get allFolders sync* {
    Iterable<Folder> walk(List<TreeNode> nodes) sync* {
      for (final n in nodes) {
        if (n is FolderNode) {
          yield n.folder;
          yield* walk(n.children);
        }
      }
    }

    yield* walk(children);
  }
}

/// Where a request or folder should be placed.
@immutable
class TreeLocation {
  const TreeLocation(this.collectionId, [this.folderId]);

  final String collectionId;
  final String? folderId;

  @override
  bool operator ==(Object other) =>
      other is TreeLocation &&
      other.collectionId == collectionId &&
      other.folderId == folderId;

  @override
  int get hashCode => Object.hash(collectionId, folderId);
}
