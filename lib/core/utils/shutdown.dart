import 'dart:async';

/// Runs cleanup [steps] in order before the app exits, giving up after
/// [timeout] so a slow or stuck step (e.g. a database that will not close)
/// cannot keep the app open. A failing step does not stop the others.
/// Returns false when the time ran out.
Future<bool> runShutdownSteps(
  List<Future<void> Function()> steps, {
  Duration timeout = const Duration(seconds: 3),
  void Function(Object error)? onError,
}) async {
  Future<void> all() async {
    for (final step in steps) {
      try {
        await step();
      } catch (e) {
        onError?.call(e);
      }
    }
  }

  try {
    await all().timeout(timeout);
    return true;
  } on TimeoutException {
    return false;
  }
}
