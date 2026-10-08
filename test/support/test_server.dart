import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Minimal local HTTP server for exercising the real HTTP stack in tests.
class TestServer {
  TestServer._(this._server);

  final HttpServer _server;

  static Future<TestServer> start({int port = 0}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final s = TestServer._(server);
    server.listen(s._handle);
    return s;
  }

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      switch (req.uri.path) {
        case '/echo':
          final body = await utf8.decoder.bind(req).join();
          final headers = <String, String>{};
          req.headers.forEach(
            (name, values) => headers[name] = values.join(', '),
          );
          res.headers.contentType = ContentType.json;
          res.write(
            jsonEncode({
              'method': req.method,
              'path': req.uri.path,
              'query': req.uri.queryParameters,
              'headers': headers,
              'body': body,
            }),
          );
        case '/status':
          res.statusCode = int.parse(req.uri.queryParameters['code'] ?? '200');
          res.reasonPhrase = req.uri.queryParameters['reason'] ?? 'Custom';
          res.write('status');
        case '/large':
          final size = int.parse(
            req.uri.queryParameters['bytes'] ?? '${10 * 1024 * 1024}',
          );
          res.headers.contentType = ContentType.json;
          res.headers.contentLength = size;
          final chunk = List.filled(64 * 1024, 0x61);
          var remaining = size;
          while (remaining > 0) {
            final n = remaining < chunk.length ? remaining : chunk.length;
            res.add(chunk.sublist(0, n));
            remaining -= n;
          }
        case '/json':
          // Realistic nested JSON of roughly `items * 230` bytes.
          final items = int.parse(req.uri.queryParameters['items'] ?? '100');
          res.headers.contentType = ContentType.json;
          res.write('{"total":$items,"items":[');
          for (var i = 0; i < items; i++) {
            if (i > 0) res.write(',');
            res.write(
              jsonEncode({
                'id': i,
                'name': 'Item number $i',
                'active': i.isEven,
                'price': i * 1.25,
                'tags': ['alpha', 'beta', 'gamma'],
                'owner': {
                  'id': i % 97,
                  'email': 'user$i@example.com',
                  'verified': null,
                },
              }),
            );
          }
          res.write(']}');
        case '/slow':
          final ms = int.parse(req.uri.queryParameters['ms'] ?? '2000');
          await Future<void>.delayed(Duration(milliseconds: ms));
          res.write('slow');
        case '/redirect':
          res.statusCode = HttpStatus.found;
          res.headers.set(HttpHeaders.locationHeader, '/echo');
        case '/cookie':
          res.cookies.add(Cookie('session', 'abc123')..path = '/');
          res.write('cookie set');
        case '/count':
          // Streams the body without buffering it (large upload tests).
          var length = 0;
          await for (final chunk in req) {
            length += chunk.length;
          }
          res.headers.contentType = ContentType.json;
          res.write(
            jsonEncode({
              'contentType': req.headers.contentType?.mimeType ?? '',
              'length': length,
            }),
          );
        case '/upload':
          final contentType = req.headers.contentType?.mimeType ?? '';
          final bytes = await req.fold<List<int>>([], (a, b) => a..addAll(b));
          res.headers.contentType = ContentType.json;
          res.write(
            jsonEncode({
              'contentType': contentType,
              'length': bytes.length,
              'raw': latin1.decode(bytes),
            }),
          );
        case '/binary':
          res.headers.contentType = ContentType('image', 'png');
          res.add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0]);
        default:
          res.statusCode = HttpStatus.notFound;
          res.write('not found');
      }
    } catch (_) {
      // The client may have disconnected (cancellation tests).
    }
    try {
      await res.close();
    } catch (_) {}
  }
}

/// Returns a TCP port with nothing listening on it.
Future<int> unusedPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}
