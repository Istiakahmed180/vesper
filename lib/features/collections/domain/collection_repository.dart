import '../../api_client/domain/models/api_request.dart';
import '../../api_client/domain/models/saved_response.dart';
import 'collection_models.dart';

/// Portable collection content used for import, export, duplicate and sync.
class CollectionDocument {
  const CollectionDocument({
    required this.name,
    this.description = '',
    this.items = const [],
    this.settings = const CollectionSettings(),
  });

  final String name;
  final String description;
  final List<CollectionItem> items;

  /// Collection-level authorization and variables.
  final CollectionSettings settings;
}

sealed class CollectionItem {
  const CollectionItem();
}

class FolderItem extends CollectionItem {
  const FolderItem(this.name, this.items);
  final String name;
  final List<CollectionItem> items;
}

class RequestItem extends CollectionItem {
  const RequestItem(this.request);
  final ApiRequest request;
}

abstract class CollectionRepository {
  /// Emits the full tree whenever collections, folders or requests change.
  /// Requests in the tree do not carry secret auth values.
  Stream<List<CollectionTree>> watchTrees();

  Future<Collection> createCollection(String name, {String description = ''});
  Future<void> updateCollection(String id, {String? name, String? description});
  Future<void> deleteCollection(String id);
  Future<String> duplicateCollection(String id);
  Future<void> reorderCollection(String id, int newIndex);

  /// Moves a collection with everything in it to another workspace.
  Future<void> moveCollectionToWorkspace(String id, String workspaceId);

  /// Collection authorization and variables, secrets included. Null when the
  /// collection does not exist.
  Future<CollectionSettings?> getSettings(String id);

  /// Emits [getSettings] whenever collections change.
  Stream<CollectionSettings?> watchSettings(String id);

  /// Persists collection settings, routing secrets to the vault.
  Future<void> saveSettings(String id, CollectionSettings settings);

  Future<Folder> createFolder(
    String collectionId,
    String name, {
    String? parentId,
  });
  Future<void> renameFolder(String id, String name);
  Future<void> deleteFolder(String id);
  Future<String> duplicateFolder(String id);
  Future<void> moveFolder(String id, TreeLocation target, {int? index});

  /// Returns the request including secret auth values from the vault.
  Future<ApiRequest?> getRequest(String id);

  /// Inserts or updates [request]. It must have a collectionId.
  Future<ApiRequest> saveRequest(ApiRequest request);
  Future<void> renameRequest(String id, String name);

  /// Replaces the saved example responses of request [id] without touching
  /// the rest of the request.
  Future<void> saveExamples(String id, List<SavedResponse> examples);
  Future<void> deleteRequest(String id);
  Future<ApiRequest> duplicateRequest(String id);

  /// Overwrites the saved request [id] with the content of [source] (name
  /// included) while keeping its id and place in the tree.
  Future<ApiRequest> replaceRequest(String id, ApiRequest source);
  Future<void> moveRequest(String id, TreeLocation target, {int? index});

  /// Exports a collection including secrets only when [includeSecrets].
  Future<CollectionDocument> exportCollection(
    String id, {
    bool includeSecrets = false,
  });

  /// Exports one folder as a collection document named after the folder,
  /// with the folder's contents and the collection's auth and variables.
  Future<CollectionDocument> exportFolder(
    String id, {
    bool includeSecrets = false,
  });

  /// Exports one request as a collection document named after the request,
  /// with the collection's auth and variables.
  Future<CollectionDocument> exportRequest(
    String id, {
    bool includeSecrets = false,
  });

  /// Creates a new collection from [document] and returns its id.
  Future<String> importCollection(CollectionDocument document);

  /// Appends the items of [document] to an existing collection, at its root
  /// or inside [folderId]. The collection's name, description and settings
  /// are left unchanged.
  Future<void> importIntoCollection(
    String id,
    CollectionDocument document, {
    String? folderId,
  });

  /// Replaces the contents of an existing collection (used by sync pull).
  Future<void> replaceCollection(String id, CollectionDocument document);
}
