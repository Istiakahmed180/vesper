import 'package:flutter/foundation.dart';

/// A separate set of collections, environments, history and open tabs.
@immutable
class Workspace {
  const Workspace({
    required this.id,
    required this.name,
    this.sortOrder = 0,
    this.activeEnvironmentId,
  });

  final String id;
  final String name;
  final int sortOrder;

  /// The environment selected in this workspace (not the Globals).
  final String? activeEnvironmentId;

  @override
  bool operator ==(Object other) =>
      other is Workspace &&
      other.id == id &&
      other.name == name &&
      other.sortOrder == sortOrder &&
      other.activeEnvironmentId == activeEnvironmentId;

  @override
  int get hashCode => Object.hash(id, name, sortOrder, activeEnvironmentId);
}
