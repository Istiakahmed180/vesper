import 'dart:async';
import 'dart:io';

import '../errors/app_failure.dart';

/// Receives an OAuth authorization response on a loopback HTTP server
/// (RFC 8252 §7.3). The server listens on 127.0.0.1 with an OS-assigned port
/// and accepts exactly one callback whose `state` matches.
class LoopbackReceiver {
  LoopbackReceiver._(this._server, this.callbackPath);

  final HttpServer _server;
  final String callbackPath;

  static Future<LoopbackReceiver> start({
    String callbackPath = '/callback',
    int port = 0,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    return LoopbackReceiver._(server, callbackPath);
  }

  String get redirectUri => 'http://127.0.0.1:${_server.port}$callbackPath';

  /// Waits for the redirect and returns its query parameters. A null
  /// [expectedState] skips the state check (the authorization server verifies
  /// it itself, as in Supabase's PKCE flow).
  Future<Map<String, String>> waitForCallback({
    required String? expectedState,
    Duration timeout = const Duration(minutes: 5),
    Future<void>? cancelled,
  }) async {
    final completer = Completer<Map<String, String>>();
    late final StreamSubscription<HttpRequest> sub;
    sub = _server.listen((request) async {
      if (request.uri.path != callbackPath) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final params = request.uri.queryParameters;
      final stateOk = expectedState == null || params['state'] == expectedState;
      final ok = stateOk && params['error'] == null && params['code'] != null;
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..write(_page(ok));
      await request.response.close();
      if (completer.isCompleted) return;
      if (!stateOk) {
        completer.completeError(
          const AuthFailure(
            AuthFailureKind.invalidResponse,
            'The authorization response could not be verified (state mismatch).',
          ),
        );
      } else if (params['error'] != null) {
        completer.completeError(
          AuthFailure(
            params['error'] == 'access_denied'
                ? AuthFailureKind.denied
                : AuthFailureKind.invalidResponse,
            params['error'] == 'access_denied'
                ? 'Access was denied.'
                : 'Authorization failed: ${params['error_description'] ?? params['error']}',
          ),
        );
      } else {
        completer.complete(params);
      }
    });

    unawaited(
      cancelled?.then((_) {
        if (!completer.isCompleted) {
          completer.completeError(
            const AuthFailure(
              AuthFailureKind.cancelled,
              'Sign-in was cancelled.',
            ),
          );
        }
      }),
    );

    try {
      return await completer.future.timeout(
        timeout,
        onTimeout: () => throw const AuthFailure(
          AuthFailureKind.cancelled,
          'Sign-in timed out. Please try again.',
        ),
      );
    } finally {
      await sub.cancel();
      await close();
    }
  }

  Future<void> close() => _server.close(force: true);

  static String _page(bool ok) =>
      '''
<!doctype html><html><head><meta charset="utf-8"><title>Vesper</title>
<style>body{font-family:-apple-system,Segoe UI,sans-serif;background:#15171c;color:#e6e8ee;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
.card{padding:32px 40px;border:1px solid #2a2e38;border-radius:12px;background:#1d2027;text-align:center}
h1{font-size:18px;margin:0 0 8px}p{color:#a9aebc;margin:0}</style></head>
<body><div class="card"><h1>${ok ? 'You are signed in' : 'Sign-in failed'}</h1>
<p>${ok ? 'You can close this window and return to Vesper.' : 'Return to Vesper for details.'}</p></div></body></html>''';
}
