import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/utils/json_read.dart';
import '../../api_client/domain/models/api_request.dart';
import '../../api_client/domain/models/key_value.dart';
import '../../api_client/domain/services/url_utils.dart';
import '../../collections/domain/collection_models.dart';
import '../../collections/presentation/collection_providers.dart';
import '../../settings/data/settings_repository.dart';
import '../../settings/domain/app_settings.dart';
import '../../workspaces/presentation/workspace_providers.dart';
import '../domain/workspace_models.dart';
import 'response_controller.dart';

final workspaceProvider = NotifierProvider<WorkspaceController, WorkspaceState>(
  WorkspaceController.new,
);

/// The active tab id; widgets watch this instead of the whole workspace.
final activeTabIdProvider = Provider<String?>(
  (ref) => ref.watch(workspaceProvider.select((s) => s.activeTab?.id)),
);

/// The draft of a request tab, selected so editors rebuild only for their tab.
final requestTabProvider = Provider.family<RequestTab?, String>((ref, tabId) {
  final tab = ref.watch(workspaceProvider.select((s) => s.tab(tabId)));
  return tab is RequestTab ? tab : null;
});

/// Open tabs of the active workspace. Tabs of other workspaces are parked in
/// memory (unsaved drafts included) and come back when switching back.
class WorkspaceController extends Notifier<WorkspaceState> {
  Timer? _persistTimer;
  late String _workspaceId;
  final _parked = <String, WorkspaceState>{};

  @override
  WorkspaceState build() {
    _parked.clear();
    _workspaceId = ref.read(activeWorkspaceIdProvider);
    ref.listen(activeWorkspaceIdProvider, (_, next) => _switchWorkspace(next));
    ref.listen(collectionTreesProvider, (_, next) {
      // While rescoping to another workspace the provider still holds the
      // previous workspace's trees; syncing against them would unlink tabs.
      if (next.isLoading) return;
      final trees = next.value;
      if (trees != null) _syncWithSavedRequests(trees);
    });
    ref.onDispose(() => _persistTimer?.cancel());
    return _blankState();
  }

  static WorkspaceState _blankState() {
    final first = RequestTab(draft: ApiRequest());
    return WorkspaceState(tabs: [first], activeTabId: first.id);
  }

  void _switchWorkspace(String next) {
    final previous = _workspaceId;
    if (next == previous) return;
    if (_persistTimer?.isActive ?? false) {
      _persistTimer!.cancel();
      _persist(previous, state);
    }
    _parked[previous] = state;
    _workspaceId = next;
    final parked = _parked.remove(next);
    if (parked != null) {
      state = parked;
      return;
    }
    state = _blankState();
    unawaited(_restoreTabs(next));
  }

  // ------------------------------------------------------------------ tabs

  void activate(String tabId) {
    if (state.tab(tabId) != null) {
      _set(state.copyWith(activeTabId: () => tabId));
    }
  }

  String newRequestTab([ApiRequest? request, String? notice]) {
    final tab = RequestTab(
      draft: _syncParams(request ?? ApiRequest()),
      notice: notice,
    );
    final index = _activeIndex + 1;
    final tabs = [...state.tabs]
      ..insert(index.clamp(0, state.tabs.length), tab);
    _set(WorkspaceState(tabs: tabs, activeTabId: tab.id));
    return tab.id;
  }

  /// Opens a saved request, focusing an existing tab when already open.
  Future<void> openSavedRequest(String requestId) async {
    final existing = state.tabs
        .whereType<RequestTab>()
        .where((t) => t.savedRequestId == requestId)
        .firstOrNull;
    if (existing != null) return activate(existing.id);
    final request = await ref
        .read(collectionRepositoryProvider)
        .getRequest(requestId);
    if (request == null) return;
    final synced = _syncParams(request);
    final tab = RequestTab(draft: synced, baseline: synced);
    // Replace an untouched blank tab instead of piling up empty tabs.
    final active = state.activeTab;
    if (active is RequestTab && !active.isSaved && !active.isDirty) {
      _replaceTab(active.id, tab);
      ref.invalidate(responseProvider(active.id));
    } else {
      final tabs = [...state.tabs]..insert(_activeIndex + 1, tab);
      _set(WorkspaceState(tabs: tabs, activeTabId: tab.id));
    }
  }

  void openEnvironment(String environmentId, String name) {
    final existing = state.tabs
        .whereType<EnvironmentTab>()
        .where((t) => t.environmentId == environmentId)
        .firstOrNull;
    if (existing != null) return activate(existing.id);
    final tab = EnvironmentTab(environmentId: environmentId, name: name);
    final tabs = [...state.tabs]..insert(_activeIndex + 1, tab);
    _set(WorkspaceState(tabs: tabs, activeTabId: tab.id));
  }

  void closeTab(String tabId) {
    final index = state.tabs.indexWhere((t) => t.id == tabId);
    if (index == -1) return;
    final tabs = [...state.tabs]..removeAt(index);
    ref.read(responseProvider(tabId).notifier).cancel();
    ref.invalidate(responseProvider(tabId));
    if (tabs.isEmpty) {
      final blank = RequestTab(draft: ApiRequest());
      _set(WorkspaceState(tabs: [blank], activeTabId: blank.id));
      return;
    }
    var active = state.activeTabId;
    if (active == tabId) active = tabs[(index).clamp(0, tabs.length - 1)].id;
    _set(WorkspaceState(tabs: tabs, activeTabId: active));
  }

  void closeOtherTabs(String keepId) {
    for (final t in state.tabs.where((t) => t.id != keepId).toList()) {
      ref.invalidate(responseProvider(t.id));
    }
    _set(
      WorkspaceState(
        tabs: state.tabs.where((t) => t.id == keepId).toList(),
        activeTabId: keepId,
      ),
    );
  }

  void duplicateTab(String tabId) {
    final tab = state.tab(tabId);
    if (tab is! RequestTab) return;
    newRequestTab(
      tab.draft.copyWith(
        id: ApiRequest().id,
        name: '${tab.draft.name} copy',
        collectionId: () => null,
        folderId: () => null,
      ),
    );
  }

  void moveTab(int from, int to) {
    if (from < 0 || from >= state.tabs.length) return;
    final tabs = [...state.tabs];
    final tab = tabs.removeAt(from);
    tabs.insert(to.clamp(0, tabs.length), tab);
    _set(state.copyWith(tabs: tabs));
  }

  void cycleTab(int delta) {
    if (state.tabs.length < 2) return;
    final next = (_activeIndex + delta) % state.tabs.length;
    activate(state.tabs[next < 0 ? next + state.tabs.length : next].id);
  }

  // ----------------------------------------------------------------- edits

  void updateDraft(String tabId, ApiRequest Function(ApiRequest draft) change) {
    final tab = state.tab(tabId);
    if (tab is! RequestTab) return;
    _replaceTab(tabId, tab.copyWith(draft: change(tab.draft)), persist: false);
  }

  /// Updates the URL and re-derives the params table from it.
  void setUrl(String tabId, String url) => updateDraft(
    tabId,
    (d) => d.copyWith(url: url, params: UrlUtils.paramsFromUrl(url, d.params)),
  );

  /// Updates the params table and rewrites the URL's query string.
  void setParams(String tabId, List<KeyValue> params) => updateDraft(
    tabId,
    (d) =>
        d.copyWith(params: params, url: UrlUtils.urlWithParams(d.url, params)),
  );

  void dismissNotice(String tabId) {
    final tab = state.tab(tabId);
    if (tab is RequestTab) _replaceTab(tabId, tab.copyWith(notice: () => null));
  }

  /// Saves the tab's draft. When [location] is given (Save As / first save)
  /// a new saved request is created there.
  Future<ApiRequest?> save(
    String tabId, {
    TreeLocation? location,
    String? name,
  }) async {
    final tab = state.tab(tabId);
    if (tab is! RequestTab) return null;
    final repo = ref.read(collectionRepositoryProvider);
    ApiRequest toSave;
    if (location != null) {
      toSave = tab.draft.copyWith(
        id: tab.isSaved ? ApiRequest().id : tab.draft.id,
        name: name ?? tab.draft.name,
        collectionId: () => location.collectionId,
        folderId: () => location.folderId,
      );
    } else if (tab.isSaved) {
      toSave = tab.draft.copyWith(
        collectionId: () => tab.baseline!.collectionId,
        folderId: () => tab.baseline!.folderId,
      );
    } else {
      return null;
    }
    final saved = await repo.saveRequest(toSave);
    final current = state.tab(tabId);
    if (current is RequestTab) {
      _replaceTab(tabId, current.copyWith(draft: saved, baseline: () => saved));
    }
    ref.read(expandedNodesProvider.notifier).expand([
      saved.collectionId!,
      if (saved.folderId != null) saved.folderId!,
    ]);
    return saved;
  }

  // ------------------------------------------------------------ persistence

  Future<void> restore(StartupBehavior behavior) async {
    if (behavior != StartupBehavior.restoreTabs) return;
    await _restoreTabs(_workspaceId);
  }

  /// Reopens the saved requests that were open in [workspaceId], unless the
  /// user started working in the meantime.
  Future<void> _restoreTabs(String workspaceId) async {
    final json = await ref
        .read(settingsRepositoryProvider)
        .readJson(SettingsRepository.tabsKey(workspaceId));
    if (json == null) return;
    final repo = ref.read(collectionRepositoryProvider);
    final tabs = <WorkspaceTab>[];
    String? activeId;
    final savedActive = json.str('active');
    for (final t in json.objList('tabs')) {
      final requestId = t.strOrNull('requestId');
      if (requestId == null) continue;
      final request = await repo.getRequest(requestId);
      if (request == null) continue;
      final synced = _syncParams(request);
      final tab = RequestTab(draft: synced, baseline: synced);
      tabs.add(tab);
      if (requestId == savedActive) activeId = tab.id;
    }
    final current = state.tabs;
    final untouched =
        current.length == 1 &&
        current.single is RequestTab &&
        !(current.single as RequestTab).isSaved &&
        !current.single.isDirty;
    if (tabs.isEmpty || workspaceId != _workspaceId || !untouched) return;
    _set(
      WorkspaceState(tabs: tabs, activeTabId: activeId ?? tabs.first.id),
      persist: false,
    );
  }

  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(
      const Duration(milliseconds: 600),
      () => _persist(_workspaceId, state),
    );
  }

  void _persist(String workspaceId, WorkspaceState snapshot) {
    final saved = snapshot.tabs
        .whereType<RequestTab>()
        .where((t) => t.isSaved)
        .toList();
    final active = snapshot.activeTab;
    unawaited(
      ref.read(settingsRepositoryProvider).writeJson(
        SettingsRepository.tabsKey(workspaceId),
        {
          'tabs': [
            for (final t in saved) {'requestId': t.savedRequestId},
          ],
          if (active is RequestTab && active.isSaved)
            'active': active.savedRequestId,
        },
      ),
    );
  }

  // ---------------------------------------------------------------- helpers

  /// The params table mirrors the URL's query; requests stored or imported
  /// without one get it rebuilt so editing the table never drops the query.
  static ApiRequest _syncParams(ApiRequest r) =>
      r.copyWith(params: UrlUtils.paramsFromUrl(r.url, r.params));

  int get _activeIndex {
    final i = state.tabs.indexWhere((t) => t.id == state.activeTab?.id);
    return i == -1 ? state.tabs.length - 1 : i;
  }

  void _replaceTab(String tabId, WorkspaceTab tab, {bool persist = true}) {
    final tabs = [for (final t in state.tabs) t.id == tabId ? tab : t];
    final active = state.activeTabId == tabId ? tab.id : state.activeTabId;
    _set(
      WorkspaceState(tabs: tabs, activeTabId: active),
      persist: persist,
    );
  }

  void _set(WorkspaceState next, {bool persist = true}) {
    state = next;
    if (persist) _schedulePersist();
  }

  /// Keeps open tabs consistent with renames/deletes made in the sidebar.
  void _syncWithSavedRequests(List<CollectionTree> trees) {
    final byId = {
      for (final t in trees)
        for (final r in t.allRequests) r.id: r,
    };
    var changed = false;
    final tabs = <WorkspaceTab>[];
    for (final tab in state.tabs) {
      if (tab is RequestTab && tab.isSaved) {
        final saved = byId[tab.savedRequestId];
        if (saved == null) {
          // Deleted: keep the draft as an unsaved request.
          tabs.add(tab.copyWith(baseline: () => null));
          changed = true;
          continue;
        }
        final baseline = tab.baseline!;
        if (saved.name != baseline.name ||
            saved.collectionId != baseline.collectionId ||
            saved.folderId != baseline.folderId) {
          final wasClean = !tab.isDirty;
          final newBaseline = baseline.copyWith(
            name: saved.name,
            collectionId: () => saved.collectionId,
            folderId: () => saved.folderId,
          );
          tabs.add(
            tab.copyWith(
              baseline: () => newBaseline,
              draft: wasClean || tab.draft.name == baseline.name
                  ? tab.draft.copyWith(name: saved.name)
                  : tab.draft,
            ),
          );
          changed = true;
          continue;
        }
      }
      tabs.add(tab);
    }
    if (changed) _set(state.copyWith(tabs: tabs), persist: false);
  }
}
