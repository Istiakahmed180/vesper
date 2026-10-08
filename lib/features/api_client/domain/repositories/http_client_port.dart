import '../../../../core/network/cancel_handle.dart';
import '../../../settings/domain/app_settings.dart';
import '../models/api_response.dart';
import '../models/prepared_request.dart';

/// Sends prepared requests. Implementations must throw only
/// [NetworkFailure]s so callers never see transport-specific exceptions.
abstract class HttpClientPort {
  Future<ApiResponse> send(
    PreparedRequest request, {
    required NetworkSettings settings,
    CancelHandle? cancel,
  });

  void dispose();
}
