import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/utils/json_read.dart';
import '../domain/github_models.dart';

/// A file fetched from a repository.
class RemoteFile {
  const RemoteFile({
    required this.path,
    required this.sha,
    required this.content,
  });
  final String path;
  final String sha;
  final String content;
}

class RemoteEntry {
  const RemoteEntry({
    required this.path,
    required this.sha,
    required this.isFile,
  });
  final String path;
  final String sha;
  final bool isFile;
}

/// Raised when a write is rejected because the remote file changed.
class RemoteConflict extends SyncFailure {
  const RemoteConflict(String path)
    : super(
        'The file "$path" changed on GitHub since it was last synced. Review the conflict before overwriting.',
      );
}

/// Thin GitHub REST v3 client. Every method maps HTTP failures to
/// [AuthFailure] / [SyncFailure] with readable messages.
class GitHubApi {
  GitHubApi({
    required this.logger,
    Dio? dio,
    this.baseUrl = 'https://api.github.com',
    this.oauthBaseUrl = 'https://github.com',
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 20),
               receiveTimeout: const Duration(seconds: 60),
               validateStatus: (_) => true,
               responseType: ResponseType.plain,
             ),
           );

  final AppLogger logger;
  final Dio _dio;
  final String baseUrl;
  final String oauthBaseUrl;

  String get _deviceCodeUrl => '$oauthBaseUrl/login/device/code';
  String get _tokenUrl => '$oauthBaseUrl/login/oauth/access_token';

  // ---------------------------------------------------------- device flow

  Future<DeviceCode> requestDeviceCode({
    required String clientId,
    required String scopes,
  }) async {
    final json = await _formPost(_deviceCodeUrl, {
      'client_id': clientId,
      'scope': scopes,
    });
    if (json.strOrNull('error') != null) {
      throw AuthFailure(
        AuthFailureKind.notConfigured,
        json.str('error') == 'device_flow_disabled'
            ? 'Device flow is disabled for this GitHub OAuth app. Enable it in the app settings on GitHub.'
            : 'GitHub rejected the request: ${json.str('error_description', json.str('error'))}',
      );
    }
    return DeviceCode(
      deviceCode: json.str('device_code'),
      userCode: json.str('user_code'),
      verificationUri: json.str(
        'verification_uri',
        'https://github.com/login/device',
      ),
      expiresIn: Duration(seconds: json.integer('expires_in', 900)),
      interval: Duration(seconds: json.integer('interval', 5)),
    );
  }

  /// Polls until the user authorizes the device, then returns the token JSON.
  Future<JsonMap> pollForToken({
    required String clientId,
    required DeviceCode code,
    Future<void>? cancelled,
  }) async {
    var interval = code.interval;
    final deadline = DateTime.now().add(code.expiresIn);
    var isCancelled = false;
    unawaited(cancelled?.then((_) => isCancelled = true));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(interval);
      if (isCancelled) {
        throw const AuthFailure(
          AuthFailureKind.cancelled,
          'GitHub connection was cancelled.',
        );
      }
      final json = await _formPost(_tokenUrl, {
        'client_id': clientId,
        'device_code': code.deviceCode,
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
      });
      switch (json.strOrNull('error')) {
        case null:
          if (json.str('access_token').isEmpty) {
            throw const AuthFailure(
              AuthFailureKind.invalidResponse,
              'GitHub returned no access token.',
            );
          }
          return json;
        case 'authorization_pending':
          continue;
        case 'slow_down':
          interval += const Duration(seconds: 5);
        case 'expired_token':
          throw const AuthFailure(
            AuthFailureKind.expired,
            'The GitHub code expired. Please try again.',
          );
        case 'access_denied':
          throw const AuthFailure(
            AuthFailureKind.denied,
            'GitHub access was denied.',
          );
        default:
          throw AuthFailure(
            AuthFailureKind.invalidResponse,
            'GitHub authorization failed: ${json.str('error_description', json.str('error'))}',
          );
      }
    }
    throw const AuthFailure(
      AuthFailureKind.expired,
      'The GitHub code expired. Please try again.',
    );
  }

  Future<JsonMap> _formPost(String url, Map<String, String> form) async {
    try {
      final res = await _dio.post<String>(
        url,
        data: form,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: {'Accept': 'application/json'},
        ),
      );
      final decoded = jsonDecode(res.data ?? '{}');
      return decoded is Map ? decoded.cast<String, Object?>() : {};
    } on DioException {
      throw const AuthFailure(
        AuthFailureKind.network,
        'Could not reach GitHub. Check your connection.',
      );
    } on FormatException {
      throw const AuthFailure(
        AuthFailureKind.invalidResponse,
        'Unexpected response from GitHub.',
      );
    }
  }

  // ------------------------------------------------------------- REST API

  Future<(int, Object?, Headers)> _api(
    String method,
    String path, {
    required String token,
    Map<String, Object?>? query,
    Object? body,
  }) async {
    try {
      final res = await _dio.request<String>(
        '$baseUrl$path',
        queryParameters: query,
        data: body == null ? null : jsonEncode(body),
        options: Options(
          method: method,
          headers: {
            'Authorization': 'Bearer $token',
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
            if (body != null) 'Content-Type': 'application/json',
          },
        ),
      );
      final status = res.statusCode ?? 0;
      Object? json;
      try {
        json = (res.data ?? '').isEmpty ? null : jsonDecode(res.data!);
      } on FormatException {
        json = null;
      }
      if (status == 401) {
        logger.warning('GitHub token rejected', {'status': status});
        throw const AuthFailure(
          AuthFailureKind.expired,
          'GitHub authorization expired. Please reconnect your account.',
        );
      }
      if (status == 403 && res.headers.value('x-ratelimit-remaining') == '0') {
        throw const SyncFailure(
          'GitHub API rate limit reached. Try again later.',
        );
      }
      return (status, json, res.headers);
    } on DioException {
      throw const SyncFailure('Could not reach GitHub. Check your connection.');
    }
  }

  Future<GitHubAccount> currentUser(String token) async {
    final (status, json, headers) = await _api('GET', '/user', token: token);
    if (status != 200 || json is! Map) {
      throw const SyncFailure('Could not load your GitHub profile.');
    }
    return GitHubAccount.fromJson(json.cast<String, Object?>());
  }

  /// Returns the scopes granted to [token] (classic OAuth tokens only).
  Future<String> grantedScopes(String token) async {
    final (_, _, headers) = await _api('GET', '/user', token: token);
    return headers.value('x-oauth-scopes') ?? '';
  }

  Future<List<GitHubRepo>> listRepos(String token, {int maxPages = 10}) async {
    final repos = <GitHubRepo>[];
    for (var page = 1; page <= maxPages; page++) {
      final (status, json, _) = await _api(
        'GET',
        '/user/repos',
        token: token,
        query: {
          'per_page': 100,
          'page': page,
          'sort': 'updated',
          'affiliation': 'owner,collaborator,organization_member',
        },
      );
      if (status != 200 || json is! List) {
        throw const SyncFailure('Could not list your repositories.');
      }
      repos.addAll([
        for (final r in json)
          if (r is Map) GitHubRepo.fromJson(r.cast<String, Object?>()),
      ]);
      if (json.length < 100) break;
    }
    return repos;
  }

  Future<GitHubRepo> getRepo(String token, String fullName) async {
    final (status, json, _) = await _api(
      'GET',
      '/repos/$fullName',
      token: token,
    );
    if (status == 404) {
      throw SyncFailure(
        'Repository "$fullName" was not found or is not accessible.',
      );
    }
    if (status != 200 || json is! Map) {
      throw const SyncFailure('Could not load the repository.');
    }
    return GitHubRepo.fromJson(json.cast<String, Object?>());
  }

  String _contentsPath(String repo, String path) =>
      '/repos/$repo/contents/${path.split('/').map(Uri.encodeComponent).join('/')}';

  Future<RemoteFile?> getFile(
    String token,
    String repo,
    String branch,
    String path,
  ) async {
    final (status, json, _) = await _api(
      'GET',
      _contentsPath(repo, path),
      token: token,
      query: {'ref': branch},
    );
    if (status == 404) return null;
    if (status != 200 || json is! Map) {
      throw SyncFailure('Could not read "$path" from GitHub.');
    }
    final m = json.cast<String, Object?>();
    final sha = m.str('sha');
    var encoded = m.str('content');
    if (m.str('encoding') != 'base64' || encoded.isEmpty) {
      // Files over 1 MB are only available through the blobs API.
      final (blobStatus, blob, _) = await _api(
        'GET',
        '/repos/$repo/git/blobs/$sha',
        token: token,
      );
      if (blobStatus != 200 || blob is! Map) {
        throw SyncFailure('Could not read "$path" from GitHub.');
      }
      encoded = blob['content']?.toString() ?? '';
    }
    final content = utf8.decode(
      base64.decode(encoded.replaceAll('\n', '')),
      allowMalformed: true,
    );
    return RemoteFile(path: path, sha: sha, content: content);
  }

  Future<List<RemoteEntry>> listDirectory(
    String token,
    String repo,
    String branch,
    String path,
  ) async {
    final (status, json, _) = await _api(
      'GET',
      _contentsPath(repo, path),
      token: token,
      query: {'ref': branch},
    );
    if (status == 404) return const [];
    if (status != 200 || json is! List) {
      throw SyncFailure('Could not list "$path" on GitHub.');
    }
    return [
      for (final e in json)
        if (e is Map)
          RemoteEntry(
            path: e['path'].toString(),
            sha: e['sha'].toString(),
            isFile: e['type'] == 'file',
          ),
    ];
  }

  /// Creates or updates a file. When [sha] is given GitHub only accepts the
  /// write if the remote file still has that sha (optimistic concurrency).
  Future<String> putFile(
    String token,
    String repo,
    String branch,
    String path, {
    required String content,
    required String message,
    String? sha,
  }) async {
    final (status, json, _) = await _api(
      'PUT',
      _contentsPath(repo, path),
      token: token,
      body: {
        'message': message,
        'content': base64.encode(utf8.encode(content)),
        'branch': branch,
        'sha': ?sha,
      },
    );
    if (status == 409 || status == 422) throw RemoteConflict(path);
    if (status == 403 || status == 404) {
      throw const SyncFailure(
        'You do not have write access to this repository or branch.',
      );
    }
    if ((status != 200 && status != 201) || json is! Map) {
      throw SyncFailure(
        'GitHub rejected the update of "$path" (HTTP $status).',
      );
    }
    return json.cast<String, Object?>().obj('content').str('sha');
  }
}
