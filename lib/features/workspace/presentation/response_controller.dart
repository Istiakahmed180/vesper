import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/network/cancel_handle.dart';
import '../../api_client/domain/models/api_request.dart';
import '../../api_client/domain/models/api_response.dart';
import '../../api_client/domain/models/saved_response.dart';
import '../../api_client/domain/usecases/send_request.dart';
import '../../collections/presentation/collection_providers.dart';
import '../../environments/presentation/environment_providers.dart';
import '../../settings/presentation/settings_controller.dart';
import '../domain/workspace_models.dart';
import 'variable_updater.dart';
import 'workspace_controller.dart';

@immutable
sealed class ResponseState {
  const ResponseState();
}

class ResponseIdle extends ResponseState {
  const ResponseIdle();
}

class ResponseLoading extends ResponseState {
  const ResponseLoading(this.startedAt, this.handle);
  final DateTime startedAt;
  final CancelHandle handle;
}

class ResponseSuccess extends ResponseState {
  const ResponseSuccess(
    this.response, {
    this.notes = const [],
    this.example,
  });
  final ApiResponse response;

  /// Set when [response] is a saved example rather than a live response.
  final SavedResponse? example;

  /// Results of the request's "Set variables" rules.
  final List<ExtractionNote> notes;
}

class ResponseFailure extends ResponseState {
  const ResponseFailure(this.failure);
  final AppFailure failure;
}

final sendRequestUseCaseProvider = Provider<SendRequestUseCase>(
  (ref) => SendRequestUseCase(
    client: ref.watch(httpClientProvider),
    history: ref.watch(historyRepositoryProvider),
  ),
);

/// Response state per workspace tab.
final responseProvider =
    NotifierProvider.family<ResponseController, ResponseState, String>(
      ResponseController.new,
    );

class ResponseController extends Notifier<ResponseState> {
  ResponseController(this.tabId);

  final String tabId;
  int _generation = 0;

  @override
  ResponseState build() => const ResponseIdle();

  bool get isLoading => state is ResponseLoading;

  Future<void> send() async {
    final tab = ref.read(workspaceProvider).tab(tabId);
    if (tab is! RequestTab) return;
    cancel();
    final handle = CancelHandle();
    final generation = ++_generation;
    state = ResponseLoading(DateTime.now(), handle);
    try {
      final context = await loadRequestContext(
        (id) => ref.read(collectionRepositoryProvider).getSettings(id),
        ref.read(variableResolverProvider),
        tab.draft.collectionId,
      );
      final response = await ref.read(sendRequestUseCaseProvider)(
        tab.draft,
        resolver: context.resolver,
        inheritedAuth: context.inheritedAuth,
        settings: ref.read(settingsProvider),
        savedRequestId: tab.savedRequestId,
        cancel: handle,
      );
      if (generation == _generation && ref.mounted) {
        state = ResponseSuccess(response);
      }
      final notes = await _setVariables(tab.draft, response);
      if (notes.isNotEmpty && generation == _generation && ref.mounted) {
        state = ResponseSuccess(response, notes: notes);
      }
    } on AppFailure catch (failure) {
      if (generation == _generation && ref.mounted) {
        state = ResponseFailure(failure);
      }
    } catch (error, stack) {
      ref
          .read(loggerProvider)
          .error('Unexpected send error', error: error, stackTrace: stack);
      if (generation == _generation && ref.mounted) {
        state = const ResponseFailure(UnexpectedFailure());
      }
    }
  }

  Future<List<ExtractionNote>> _setVariables(
    ApiRequest request,
    ApiResponse response,
  ) async {
    try {
      return await applyExtractions(ref, request, response);
    } catch (e) {
      return [
        ExtractionNote(
          'Variables could not be updated: ${e.userMessage}',
          ok: false,
        ),
      ];
    }
  }

  /// Shows a saved example in place of the live response.
  void viewExample(SavedResponse example) {
    final tab = ref.read(workspaceProvider).tab(tabId);
    if (tab is! RequestTab) return;
    cancel();
    state = ResponseSuccess(
      example.toApiResponse(
        requestUrl: tab.draft.url,
        method: tab.draft.method,
      ),
      example: example,
    );
  }

  /// Whether the current live response can be saved as an example.
  bool get canSaveExample {
    final current = state;
    return current is ResponseSuccess &&
        current.example == null &&
        SavedResponse.canSave(current.response);
  }

  /// Saves the live response on the saved request. Returns null when there is
  /// nothing to save.
  Future<SavedResponse?> saveExample({String? name}) async {
    final current = state;
    final tab = ref.read(workspaceProvider).tab(tabId);
    if (current is! ResponseSuccess ||
        current.example != null ||
        tab is! RequestTab ||
        !tab.isSaved) {
      return null;
    }
    final example = SavedResponse.fromApiResponse(
      current.response,
      name: name,
    );
    await ref.read(workspaceProvider.notifier).setExamples(tabId, [
      ...tab.draft.examples,
      example,
    ]);
    return example;
  }

  Future<void> renameExample(String id, String name) async {
    final tab = ref.read(workspaceProvider).tab(tabId);
    if (tab is! RequestTab || name.trim().isEmpty) return;
    await ref.read(workspaceProvider.notifier).setExamples(tabId, [
      for (final e in tab.draft.examples)
        e.id == id ? e.copyWith(name: name.trim()) : e,
    ]);
  }

  Future<void> deleteExample(String id) async {
    final tab = ref.read(workspaceProvider).tab(tabId);
    if (tab is! RequestTab) return;
    final shown = state;
    if (shown is ResponseSuccess && shown.example?.id == id) clear();
    await ref.read(workspaceProvider.notifier).setExamples(tabId, [
      for (final e in tab.draft.examples)
        if (e.id != id) e,
    ]);
  }

  void cancel() {
    final current = state;
    if (current is ResponseLoading) {
      current.handle.cancel();
      _generation++;
      state = const ResponseFailure(
        NetworkFailure(
          NetworkFailureKind.cancelled,
          'The request was cancelled.',
        ),
      );
    }
  }

  void clear() {
    cancel();
    state = const ResponseIdle();
  }
}
