import '../../../../core/errors/app_failure.dart';
import '../../../../core/network/cancel_handle.dart';
import '../../../history/domain/history_models.dart';
import '../../../history/domain/history_repository.dart';
import '../../../settings/domain/app_settings.dart';
import '../models/api_request.dart';
import '../models/api_response.dart';
import '../models/request_auth.dart';
import '../repositories/http_client_port.dart';
import '../services/request_preparer.dart';
import '../services/variable_resolver.dart';

/// Prepares, sends and records a request. Throws only [AppFailure]s.
class SendRequestUseCase {
  const SendRequestUseCase({
    required this.client,
    required this.history,
    this.preparer = const RequestPreparer(),
  });

  final HttpClientPort client;
  final HistoryRepository history;
  final RequestPreparer preparer;

  Future<ApiResponse> call(
    ApiRequest request, {
    required VariableResolver resolver,
    required AppSettings settings,
    RequestAuth? inheritedAuth,
    String? savedRequestId,
    CancelHandle? cancel,
  }) async {
    final network = settings.network;
    final prepared = preparer.prepare(
      request,
      resolver,
      inheritedAuth: inheritedAuth,
      defaults: RequestDefaults(
        timeoutMs: network.timeoutMs,
        followRedirects: network.followRedirects,
      ),
    );
    try {
      final response = await client.send(
        prepared,
        settings: network,
        cancel: cancel,
      );
      await _record(
        settings,
        HistoryEntry(
          request: request,
          requestId: savedRequestId,
          statusCode: response.statusCode,
          duration: response.duration,
          sizeBytes: response.bodySize,
        ),
      );
      return response;
    } on NetworkFailure catch (failure) {
      if (failure.kind != NetworkFailureKind.cancelled) {
        await _record(
          settings,
          HistoryEntry(
            request: request,
            requestId: savedRequestId,
            errorMessage: failure.message,
          ),
        );
      }
      rethrow;
    }
  }

  Future<void> _record(AppSettings settings, HistoryEntry entry) async {
    if (!settings.historyEnabled) return;
    try {
      await history.add(entry);
    } catch (_) {
      // History is best-effort; never fail the request because of it.
    }
  }
}
