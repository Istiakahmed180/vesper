import 'dart:convert';
import 'dart:io';

/// Fake GitHub: device flow, /user, /user/repos (paginated) and contents.
class FakeGitHub {
  late HttpServer server;
  int tokenPolls = 0;

  /// Seconds between device-flow polls GitHub asks the client to wait.
  int pollInterval = 0;
  final files = <String, (String sha, String content)>{};
  String validToken = 'gho_valid';

  String get url => 'http://127.0.0.1:${server.port}';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_handle);
  }

  Future<void> _json(HttpRequest r, int status, Object body) async {
    r.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await r.response.close();
  }

  Future<void> _handle(HttpRequest r) async {
    final path = r.uri.path;
    final body = await utf8.decoder.bind(r).join();
    if (path == '/login/device/code') {
      final form = Uri.splitQueryString(body);
      if (form['client_id'] == 'disabled') {
        return _json(r, 400, {'error': 'device_flow_disabled'});
      }
      return _json(r, 200, {
        'device_code': 'dev123',
        'user_code': 'ABCD-1234',
        'verification_uri': 'https://github.com/login/device',
        'expires_in': 30,
        'interval': pollInterval,
      });
    }
    if (path == '/login/oauth/access_token') {
      tokenPolls++;
      if (tokenPolls < 2) {
        return _json(r, 200, {'error': 'authorization_pending'});
      }
      return _json(r, 200, {
        'access_token': validToken,
        'scope': 'repo,read:user',
        'token_type': 'bearer',
      });
    }
    if (r.headers.value('authorization') != 'Bearer $validToken') {
      return _json(r, 401, {'message': 'Bad credentials'});
    }
    if (path == '/user') {
      r.response.headers.set('x-oauth-scopes', 'repo, read:user');
      return _json(r, 200, {
        'login': 'octo',
        'name': 'Octo Cat',
        'avatar_url': '',
        'html_url': '',
      });
    }
    if (path == '/user/repos') {
      final page = int.parse(r.uri.queryParameters['page'] ?? '1');
      final count = page == 1 ? 100 : 5;
      return _json(r, 200, [
        if (page == 1)
          {
            'full_name': 'octo/api',
            'private': true,
            'default_branch': 'main',
            'permissions': {'push': true},
          },
        for (var i = 0; i < count - (page == 1 ? 1 : 0); i++)
          {
            'full_name': 'octo/repo-$page-$i',
            'private': i.isEven,
            'default_branch': 'main',
            'permissions': {'push': true},
          },
      ]);
    }
    if (path.startsWith('/repos/octo/api/contents/')) {
      final filePath = Uri.decodeFull(
        path.substring('/repos/octo/api/contents/'.length),
      );
      if (r.method == 'GET') {
        if (filePath == 'api-client/collections') {
          return _json(r, 200, [
            for (final p in files.keys)
              {'path': p, 'sha': files[p]!.$1, 'type': 'file'},
          ]);
        }
        final f = files[filePath];
        if (f == null) return _json(r, 404, {'message': 'Not Found'});
        return _json(r, 200, {
          'sha': f.$1,
          'encoding': 'base64',
          'content': base64.encode(utf8.encode(f.$2)),
        });
      }
      if (r.method == 'PUT') {
        final json = jsonDecode(body) as Map<String, Object?>;
        final existing = files[filePath];
        if (existing != null && existing.$1 != json['sha']) {
          return _json(r, 409, {'message': 'sha mismatch'});
        }
        final sha = 'sha${files.length + 1}${DateTime.now().microsecond}';
        files[filePath] = (
          sha,
          utf8.decode(base64.decode(json['content']! as String)),
        );
        return _json(r, existing == null ? 201 : 200, {
          'content': {'sha': sha},
        });
      }
    }
    return _json(r, 404, {'message': 'Not Found'});
  }
}
