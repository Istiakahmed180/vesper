import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../api_client/domain/models/request_auth.dart';
import '../../api_client/domain/services/variable_resolver.dart';
import '../../environments/presentation/environment_providers.dart';
import '../domain/collection_models.dart';

final collectionTreesProvider = StreamProvider<List<CollectionTree>>(
  (ref) => ref.watch(collectionRepositoryProvider).watchTrees(),
);

/// Text typed into the sidebar search box.
final sidebarSearchProvider = NotifierProvider<SidebarSearch, String>(
  SidebarSearch.new,
);

class SidebarSearch extends Notifier<String> {
  @override
  String build() => '';
  void set(String value) => state = value;
}

/// Collections filtered by the sidebar search (matches request name, URL,
/// method and folder names). Null when no search is active.
final filteredTreesProvider = Provider<List<CollectionTree>?>((ref) {
  final query = ref.watch(sidebarSearchProvider).trim().toLowerCase();
  if (query.isEmpty) return null;
  final trees = ref.watch(collectionTreesProvider).value ?? const [];

  List<TreeNode> filter(List<TreeNode> nodes) {
    final out = <TreeNode>[];
    for (final n in nodes) {
      switch (n) {
        case FolderNode(:final folder, :final children):
          if (folder.name.toLowerCase().contains(query)) {
            out.add(n);
          } else {
            final kids = filter(children);
            if (kids.isNotEmpty) out.add(FolderNode(folder, kids));
          }
        case RequestNode(:final request):
          if (request.name.toLowerCase().contains(query) ||
              request.url.toLowerCase().contains(query) ||
              request.method.value.toLowerCase() == query) {
            out.add(n);
          }
      }
    }
    return out;
  }

  return [
    for (final t in trees)
      if (t.collection.name.toLowerCase().contains(query))
        t
      else if (filter(t.children) case final kids when kids.isNotEmpty)
        CollectionTree(t.collection, kids),
  ];
});

/// Expanded collection/folder ids in the sidebar tree.
final expandedNodesProvider = NotifierProvider<ExpandedNodes, Set<String>>(
  ExpandedNodes.new,
);

class ExpandedNodes extends Notifier<Set<String>> {
  @override
  Set<String> build() => {};

  bool isExpanded(String id) => state.contains(id);

  void toggle(String id) =>
      state = state.contains(id) ? ({...state}..remove(id)) : {...state, id};

  void expand(Iterable<String> ids) => state = {...state, ...ids};
}

/// Authorization and variables of a collection (secrets included).
final collectionSettingsProvider =
    StreamProvider.family<CollectionSettings?, String>(
      (ref, id) => ref.watch(collectionRepositoryProvider).watchSettings(id),
    );

/// Variable resolver for a request in [collectionId]: the active environment,
/// then the collection's variables, then the Globals.
final requestResolverProvider = Provider.family<VariableResolver, String?>((
  ref,
  collectionId,
) {
  final base = ref.watch(variableResolverProvider);
  if (collectionId == null) return base;
  final settings = ref.watch(collectionSettingsProvider(collectionId)).value;
  return settings == null ? base : base.withCollection(settings.toScope());
});

/// What a request in [collectionId] needs to be sent: the resolver and the
/// authorization it inherits. Waits for the collection settings to load.
Future<({VariableResolver resolver, RequestAuth? inheritedAuth})>
loadRequestContext(
  Future<CollectionSettings?> Function(String id) settingsOf,
  VariableResolver base,
  String? collectionId,
) async {
  if (collectionId == null) return (resolver: base, inheritedAuth: null);
  final settings = await settingsOf(collectionId);
  if (settings == null) return (resolver: base, inheritedAuth: null);
  return (
    resolver: base.withCollection(settings.toScope()),
    inheritedAuth: settings.auth,
  );
}
