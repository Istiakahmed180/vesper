import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/api_client/domain/services/variable_resolver.dart';
import '../../features/collections/presentation/collection_providers.dart';

/// Marks the collection whose variables the `{{variable}}` fields below it
/// can use (a request's collection, or the collection being edited).
class VariableScope extends InheritedWidget {
  const VariableScope({
    super.key,
    required this.collectionId,
    required super.child,
  });

  final String? collectionId;

  static String? collectionIdOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<VariableScope>()?.collectionId;

  /// Watches the resolver for the scope around [context].
  static VariableResolver watch(WidgetRef ref, BuildContext context) =>
      ref.watch(requestResolverProvider(collectionIdOf(context)));

  /// Reads the resolver for the scope around [context] once.
  static VariableResolver read(WidgetRef ref, BuildContext context) =>
      ref.read(requestResolverProvider(collectionIdOf(context)));

  @override
  bool updateShouldNotify(VariableScope oldWidget) =>
      oldWidget.collectionId != collectionId;
}
