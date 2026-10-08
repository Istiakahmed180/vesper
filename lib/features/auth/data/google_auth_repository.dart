import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/config/app_config.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/oauth/oauth2_client.dart';
import '../../../core/security/secret_vault.dart';
import '../../../core/utils/json_read.dart';
import '../domain/auth_models.dart';
import '../domain/auth_repository.dart';

/// Exchanges an authorization code for tokens. Two strategies exist so the
/// desktop app never has to embed a confidential secret.
abstract class GoogleTokenExchanger {
  Future<OAuth2Token> exchange({
    required String code,
    required String verifier,
    required String redirectUri,
  });
  Future<OAuth2Token> refresh(String refreshToken);
  Future<void> revoke(String token);
}

/// Recommended: a backend you operate holds the client secret.
/// Contract documented in docs/authentication.md.
class BackendGoogleExchanger implements GoogleTokenExchanger {
  BackendGoogleExchanger(this.baseUrl, {Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              validateStatus: (_) => true,
              responseType: ResponseType.plain,
            ),
          );

  final String baseUrl;
  final Dio _dio;

  Future<JsonMap> _post(String path, JsonMap body) async {
    try {
      final res = await _dio.post<String>(
        '${baseUrl.replaceAll(RegExp(r'/+$'), '')}$path',
        data: jsonEncode(body),
        options: Options(contentType: 'application/json'),
      );
      final status = res.statusCode ?? 0;
      final decoded = (res.data ?? '').isEmpty
          ? <String, Object?>{}
          : jsonDecode(res.data!);
      if (status == 401 || status == 400) {
        throw const AuthFailure(
          AuthFailureKind.expired,
          'Your session has expired. Please sign in again.',
        );
      }
      if (status >= 300 || decoded is! Map) {
        throw const AuthFailure(
          AuthFailureKind.invalidResponse,
          'The authentication server returned an error.',
        );
      }
      return decoded.cast<String, Object?>();
    } on DioException {
      throw const AuthFailure(
        AuthFailureKind.network,
        'Could not reach the authentication server.',
      );
    } on FormatException {
      throw const AuthFailure(
        AuthFailureKind.invalidResponse,
        'The authentication server returned an invalid response.',
      );
    }
  }

  @override
  Future<OAuth2Token> exchange({
    required String code,
    required String verifier,
    required String redirectUri,
  }) async => OAuth2Token.fromJson(
    await _post('/auth/google/exchange', {
      'code': code,
      'code_verifier': verifier,
      'redirect_uri': redirectUri,
    }),
  );

  @override
  Future<OAuth2Token> refresh(String refreshToken) async =>
      OAuth2Token.fromJson(
        await _post('/auth/google/refresh', {'refresh_token': refreshToken}),
      ).withRefreshFallback(refreshToken);

  @override
  Future<void> revoke(String token) async {
    try {
      await _post('/auth/google/revoke', {'token': token});
    } on AuthFailure {
      // Best effort.
    }
  }
}

/// Direct exchange with Google's token endpoint using a "Desktop app" OAuth
/// client and PKCE. Google treats installed-app secrets as non-confidential;
/// it is read from configuration, never hardcoded.
class DirectGoogleExchanger implements GoogleTokenExchanger {
  DirectGoogleExchanger({
    required this.client,
    required this.clientId,
    required this.clientSecret,
    Dio? dio,
  }) : _dio = dio ?? Dio(BaseOptions(validateStatus: (_) => true));

  final OAuth2Client client;
  final String clientId;
  final String clientSecret;
  final Dio _dio;

  static final tokenEndpoint = Uri.parse('https://oauth2.googleapis.com/token');

  @override
  Future<OAuth2Token> exchange({
    required String code,
    required String verifier,
    required String redirectUri,
  }) => client.exchangeCode(
    tokenEndpoint: tokenEndpoint,
    code: code,
    verifier: verifier,
    redirectUri: redirectUri,
    clientId: clientId,
    clientSecret: clientSecret,
  );

  @override
  Future<OAuth2Token> refresh(String refreshToken) => client.refresh(
    tokenEndpoint: tokenEndpoint,
    clientId: clientId,
    clientSecret: clientSecret,
    refreshToken: refreshToken,
  );

  @override
  Future<void> revoke(String token) async {
    try {
      await _dio.post<void>(
        'https://oauth2.googleapis.com/revoke',
        data: {'token': token},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
    } catch (_) {
      // Best effort: the local session is removed regardless.
    }
  }
}

class GoogleAuthRepository implements AuthRepository {
  GoogleAuthRepository({
    required this.config,
    required this.client,
    required this.vault,
    required this.logger,
    required this.openUrl,
    this._exchanger,
    this.userInfoUrl = 'https://openidconnect.googleapis.com/v1/userinfo',
    Dio? dio,
  }) : _dio = dio ?? Dio(BaseOptions(validateStatus: (_) => true));

  final AppConfig config;
  final OAuth2Client client;
  final SecretVault vault;
  final AppLogger logger;
  final UrlOpener openUrl;
  final GoogleTokenExchanger? _exchanger;
  final String userInfoUrl;
  final Dio _dio;

  static final authorizationEndpoint = Uri.parse(
    'https://accounts.google.com/o/oauth2/v2/auth',
  );
  static const scopes = 'openid email profile';

  GoogleTokenExchanger get exchanger =>
      _exchanger ??
      (config.hasAuthBackend
          ? BackendGoogleExchanger(config.authBackendUrl)
          : DirectGoogleExchanger(
              client: client,
              clientId: config.googleClientId,
              clientSecret: config.googleDesktopClientSecret,
            ));

  @override
  bool get isConfigured => config.isGoogleConfigured;

  @override
  Future<AuthSession> signIn({Future<void>? cancelled}) async {
    if (!isConfigured) {
      throw const AuthFailure(
        AuthFailureKind.notConfigured,
        'Google sign-in is not configured. Set GOOGLE_CLIENT_ID (see docs/authentication.md).',
      );
    }
    final token = await client.authorizationCode(
      authorizationEndpoint: authorizationEndpoint,
      tokenEndpoint: DirectGoogleExchanger.tokenEndpoint,
      clientId: config.googleClientId,
      scope: scopes,
      openUrl: openUrl,
      cancelled: cancelled,
      extraAuthParams: const {
        'access_type': 'offline',
        'prompt': 'select_account',
      },
      exchange: (code, verifier, redirectUri) => exchanger.exchange(
        code: code,
        verifier: verifier,
        redirectUri: redirectUri,
      ),
    );
    final account = await _userInfo(token.accessToken);
    final session = AuthSession(account: account, token: token);
    await _store(session);
    logger.info('Signed in', {'provider': 'google'});
    return session;
  }

  @override
  Future<AuthSession?> restore() async {
    final raw = await vault.read(VaultKeys.googleSession);
    if (raw == null) return null;
    AuthSession stored;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      stored = AuthSession.fromJson(json.cast<String, Object?>());
    } catch (_) {
      await vault.delete(VaultKeys.googleSession);
      return null;
    }
    if (!stored.token.isExpired) return stored;
    final refreshToken = stored.token.refreshToken;
    if (refreshToken == null) {
      await vault.delete(VaultKeys.googleSession);
      return null;
    }
    try {
      final token = await exchanger.refresh(refreshToken);
      final account = await _userInfo(token.accessToken);
      final session = AuthSession(account: account, token: token);
      await _store(session);
      return session;
    } on AuthFailure catch (f) {
      if (f.kind == AuthFailureKind.network) {
        return AuthSession(
          account: stored.account,
          token: stored.token,
          offline: true,
        );
      }
      logger.info('Stored session could not be refreshed; signing out');
      await vault.delete(VaultKeys.googleSession);
      return null;
    }
  }

  @override
  Future<void> signOut() async {
    final raw = await vault.read(VaultKeys.googleSession);
    await vault.delete(VaultKeys.googleSession);
    if (raw != null) {
      try {
        final session = AuthSession.fromJson(
          (jsonDecode(raw) as Map).cast<String, Object?>(),
        );
        await exchanger.revoke(
          session.token.refreshToken ?? session.token.accessToken,
        );
      } catch (_) {}
    }
    logger.info('Signed out', {'provider': 'google'});
  }

  Future<void> _store(AuthSession session) =>
      vault.write(VaultKeys.googleSession, jsonEncode(session.toJson()));

  Future<UserAccount> _userInfo(String accessToken) async {
    try {
      final res = await _dio.get<Object?>(
        userInfoUrl,
        options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
      );
      final data = res.data;
      if (res.statusCode == 401) {
        throw const AuthFailure(
          AuthFailureKind.expired,
          'Your Google session has expired.',
        );
      }
      if (res.statusCode != 200 || data is! Map) {
        throw const AuthFailure(
          AuthFailureKind.invalidResponse,
          'Could not load your Google profile.',
        );
      }
      final json = data.cast<String, Object?>();
      return UserAccount(
        id: json.str('sub'),
        email: json.str('email'),
        name: json.str('name'),
        pictureUrl: json.strOrNull('picture'),
        provider: 'google',
      );
    } on DioException {
      throw const AuthFailure(
        AuthFailureKind.network,
        'Could not reach Google.',
      );
    }
  }
}
