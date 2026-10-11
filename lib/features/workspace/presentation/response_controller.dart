import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/network/cancel_handle.dart';
import '../../api_client/domain/models/api_response.dart';
import '../../api_client/domain/usecases/send_request.dart';
import '../../collections/presentation/collection_providers.dart';
import '../../environments/presentation/environment_providers.dart';
import '../../settings/presentation/settings_controller.dart';
import '../domain/workspace_models.dart';
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
  const ResponseSuccess(this.response);
  final ApiResponse response;
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
