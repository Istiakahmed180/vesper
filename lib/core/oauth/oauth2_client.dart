import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../errors/app_failure.dart';
import '../logging/app_logger.dart';
import '../utils/json_read.dart';
import 'loopback_receiver.dart';
import 'pkce.dart';

class OAuth2Token {
  const OAuth2Token({
    required this.accessToken,
    this.refreshToken,
    this.idToken,
    this.tokenType = 'Bearer',
    this.expiresAt,
    this.scope,
  });

  final String accessToken;
  final String? refreshToken;
  final String? idToken;
  final String tokenType;
  final DateTime? expiresAt;
  final String? scope;

  bool get isExpired =>
      expiresAt != null &&
      DateTime.now().isAfter(expiresAt!.subtract(const Duration(seconds: 30)));

  factory OAuth2Token.fromJson(JsonMap json) {
    final expiresIn = json.intOrNull('expires_in');
    return OAuth2Token(
      accessToken: json.str('access_token'),
      refreshToken: json.strOrNull('refresh_token'),
      idToken: json.strOrNull('id_token'),
      tokenType: json.str('token_type', 'Bearer'),
      scope: json.strOrNull('scope'),
      expiresAt: expiresIn == null
          ? null
          : DateTime.now().add(Duration(seconds: expiresIn)),
    );
  }

  JsonMap toJson() => {
    'access_token': accessToken,
    if (refreshToken != null) 'refresh_token': refreshToken,
    if (idToken != null) 'id_token': idToken,
    'token_type': tokenType,
    if (scope != null) 'scope': scope,
    if (expiresAt != null) 'expires_at': expiresAt!.toIso8601String(),
  };

  factory OAuth2Token.fromStored(JsonMap json) => OAuth2Token(
    accessToken: json.str('access_token'),
    refreshToken: json.strOrNull('refresh_token'),
    idToken: json.strOrNull('id_token'),
    tokenType: json.str('token_type', 'Bearer'),
    scope: json.strOrNull('scope'),
    expiresAt: DateTime.tryParse(json.str('expires_at')),
  );

  OAuth2Token withRefreshFallback(String? previousRefresh) =>
      refreshToken != null
      ? this
      : OAuth2Token(
          accessToken: accessToken,
          refreshToken: previousRefresh,
          idToken: idToken,
          tokenType: tokenType,
          expiresAt: expiresAt,
          scope: scope,
        );
}

/// Opens the system browser for an authorization URL.
typedef UrlOpener = Future<bool> Function(Uri url);

/// Generic OAuth 2.0 client for public (desktop) clients: authorization code
/// with PKCE over a loopback redirect, client credentials and refresh.
class OAuth2Client {
  OAuth2Client({required this.logger, Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 30),
              validateStatus: (_) => true,
              responseType: ResponseType.plain,
            ),
          );

  final AppLogger logger;
  final Dio _dio;

  Future<OAuth2Token> authorizationCode({
    required Uri authorizationEndpoint,
    required Uri tokenEndpoint,
    required String clientId,
    required UrlOpener openUrl,
    String? clientSecret,
    String scope = '',
    Map<String, String> extraAuthParams = const {},
    Future<void>? cancelled,
    Future<OAuth2Token> Function(
      String code,
      String verifier,
      String redirectUri,
    )?
    exchange,
  }) async {
    final receiver = await LoopbackReceiver.start();
    // Read before waiting: the receiver closes its server after the callback.
    final redirectUri = receiver.redirectUri;
    final pkce = Pkce.generate();
    final state = randomState();
    final url = authorizationEndpoint.replace(
      queryParameters: {
        ...authorizationEndpoint.queryParameters,
        'response_type': 'code',
        'client_id': clientId,
        'redirect_uri': redirectUri,
        if (scope.isNotEmpty) 'scope': scope,
        'state': state,
        'code_challenge': pkce.challenge,
        'code_challenge_method': pkce.method,
        ...extraAuthParams,
      },
    );
    logger.info('OAuth authorization started', {
      'host': authorizationEndpoint.host,
    });
    final opened = await openUrl(url);
    if (!opened) {
      await receiver.close();
      throw const AuthFailure(
        AuthFailureKind.invalidResponse,
        'Could not open the browser for sign-in.',
      );
    }
    final params = await receiver.waitForCallback(
      expectedState: state,
      cancelled: cancelled,
    );
    final code = params['code']!;
    if (exchange != null) return exchange(code, pkce.verifier, redirectUri);
    return exchangeCode(
      tokenEndpoint: tokenEndpoint,
      code: code,
      verifier: pkce.verifier,
      redirectUri: redirectUri,
      clientId: clientId,
      clientSecret: clientSecret,
    );
  }

  Future<OAuth2Token> exchangeCode({
    required Uri tokenEndpoint,
    required String code,
    required String verifier,
    required String redirectUri,
    required String clientId,
    String? clientSecret,
  }) => _tokenRequest(tokenEndpoint, {
    'grant_type': 'authorization_code',
    'code': code,
    'redirect_uri': redirectUri,
    'client_id': clientId,
    'code_verifier': verifier,
    if (clientSecret != null && clientSecret.isNotEmpty)
      'client_secret': clientSecret,
  });

  Future<OAuth2Token> clientCredentials({
    required Uri tokenEndpoint,
    required String clientId,
    required String clientSecret,
    String scope = '',
  }) => _tokenRequest(tokenEndpoint, {
    'grant_type': 'client_credentials',
    'client_id': clientId,
    'client_secret': clientSecret,
    if (scope.isNotEmpty) 'scope': scope,
  });

  Future<OAuth2Token> refresh({
    required Uri tokenEndpoint,
    required String clientId,
    required String refreshToken,
    String? clientSecret,
  }) async {
    final token = await _tokenRequest(tokenEndpoint, {
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      'client_id': clientId,
      if (clientSecret != null && clientSecret.isNotEmpty)
        'client_secret': clientSecret,
    });
    return token.withRefreshFallback(refreshToken);
  }

  Future<OAuth2Token> _tokenRequest(
    Uri endpoint,
    Map<String, String> form,
  ) async {
    final Response<String> response;
    try {
      response = await _dio.postUri<String>(
        endpoint,
        data: form,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: {'Accept': 'application/json'},
        ),
      );
    } on DioException catch (e) {
      logger.error('OAuth token request failed', error: e.type.name);
      throw const AuthFailure(
        AuthFailureKind.network,
        'Could not reach the authorization server.',
      );
    }
    final json = _decode(response.data ?? '');
    final status = response.statusCode ?? 0;
    if (status >= 400 ||
        json.strOrNull('error') != null ||
        json.str('access_token').isEmpty) {
      final error = json.str('error', 'HTTP $status');
      logger.warning('OAuth token request rejected', {
        'status': status,
        'error': error,
      });
      throw AuthFailure(
        error == 'invalid_grant'
            ? AuthFailureKind.expired
            : AuthFailureKind.invalidResponse,
        'The authorization server rejected the request: ${json.str('error_description', error)}',
      );
    }
    logger.info('OAuth token received', {'host': endpoint.host});
    return OAuth2Token.fromJson(json);
  }

  static JsonMap _decode(String body) {
    try {
      final v = jsonDecode(body);
      if (v is Map) return v.cast<String, Object?>();
    } catch (_) {
      // Some servers answer with form encoding.
      try {
        return Uri.splitQueryString(body);
      } catch (_) {}
    }
    return {};
  }
}
