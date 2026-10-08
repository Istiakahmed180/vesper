import 'package:flutter/foundation.dart';

import '../../../core/utils/id.dart';
import '../../api_client/domain/models/api_request.dart';

@immutable
sealed class WorkspaceTab {
  WorkspaceTab({String? id}) : id = id ?? newId();
  final String id;
  String get title;
  bool get isDirty;
}

class RequestTab extends WorkspaceTab {
  RequestTab({super.id, required this.draft, this.baseline, this.notice});

  /// What the user is editing.
  final ApiRequest draft;

  /// Last saved version; null for requests that were never saved.
  final ApiRequest? baseline;

  /// Informational message shown above the editor (e.g. history redaction).
  final String? notice;

  bool get isSaved => baseline != null;
  String? get savedRequestId => baseline?.id;

  @override
  String get title => draft.name;

  @override
  bool get isDirty {
    final b = baseline;
    if (b == null) {
      return draft.url.isNotEmpty ||
          draft.headers.isNotEmpty ||
          draft.body.text.isNotEmpty ||
          draft.body.formData.isNotEmpty ||
          draft.body.urlEncoded.isNotEmpty;
    }
    return !draft.sameContentAs(b);
  }

  RequestTab copyWith({
    ApiRequest? draft,
    ApiRequest? Function()? baseline,
    String? Function()? notice,
  }) => RequestTab(
    id: id,
    draft: draft ?? this.draft,
    baseline: baseline != null ? baseline() : this.baseline,
    notice: notice != null ? notice() : this.notice,
  );
}

class EnvironmentTab extends WorkspaceTab {
  EnvironmentTab({super.id, required this.environmentId, required this.name});

  final String environmentId;
  final String name;

  @override
  String get title => name;

  @override
  bool get isDirty => false;
}

@immutable
class WorkspaceState {
  const WorkspaceState({this.tabs = const [], this.activeTabId});

  final List<WorkspaceTab> tabs;
  final String? activeTabId;

  WorkspaceTab? get activeTab =>
      tabs.where((t) => t.id == activeTabId).firstOrNull ?? tabs.firstOrNull;

  WorkspaceTab? tab(String id) => tabs.where((t) => t.id == id).firstOrNull;

  WorkspaceState copyWith({
    List<WorkspaceTab>? tabs,
    String? Function()? activeTabId,
  }) => WorkspaceState(
    tabs: tabs ?? this.tabs,
    activeTabId: activeTabId != null ? activeTabId() : this.activeTabId,
  );
}
