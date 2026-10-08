import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/core/config/app_config.dart';
import 'package:vesper/core/errors/app_failure.dart';
import 'package:vesper/core/logging/app_logger.dart';
import 'package:vesper/core/oauth/oauth2_client.dart';
import 'package:vesper/core/oauth/pkce.dart';
import 'package:vesper/core/security/secret_vault.dart';
import 'package:vesper/features/auth/data/google_auth_repository.dart';
import 'package:vesper/features/auth/domain/auth_models.dart';

class FakeExchanger implements GoogleTokenExchanger {
  Object? refreshError;
  int refreshes = 0;
  final revoked = <String>[];

  @override
  Future<OAuth2Token> exchange({
    required String code,
    required String verifier,
    required String redirectUri,
  }) async => OAuth2Token(
    accessToken: 'access-$code',
    refreshToken: 'refresh-1',
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
  );

  @override
  Future<OAuth2Token> refresh(String refreshToken) async {
    refreshes++;
    if (refreshError != null) throw refreshError!;
    return OAuth2Token(
      accessToken: 'refreshed',
      refreshToken: refreshToken,
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
    );
  }

  @override
  Future<void> revoke(String token) async => revoked.add(token);
}

void main() {
  late HttpServer userInfo;
  setUpAll(() async {
    userInfo = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    userInfo.listen((r) async {
      final ok = (r.headers.value('authorization') ?? '').startsWith('Bearer ');
      r.response
        ..statusCode = ok ? 200 : 401
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'sub': '42',
            'email': 'ada@example.com',
            'name': 'Ada Lovelace',
            'picture': '',
          }),
        );
      await r.response.close();
    });
  });
  tearDownAll(() => userInfo.close(force: true));

  const config = AppConfig(
    googleClientId: 'client.apps.googleusercontent.com',
    googleDesktopClientSecret: '',
    authBackendUrl: '',
    githubClientId: '',
    githubScopes: '',
    apiBaseUrl: '',
  );

  GoogleAuthRepository repo(
    SecretVault vault,
    FakeExchanger exchanger, {
    UrlOpener? opener,
  }) => GoogleAuthRepository(
    config: config,
    client: OAuth2Client(logger: AppLogger(sinks: [])),
    vault: vault,
    logger: AppLogger(sinks: []),
    openUrl: opener ?? (_) async => true,
    exchanger: exchanger,
    userInfoUrl: 'http://127.0.0.1:${userInfo.port}/userinfo',
  );

  Future<void> store(SecretVault vault, OAuth2Token token) => vault.write(
    VaultKeys.googleSession,
    jsonEncode(
      AuthSession(
        account: const UserAccount(
          id: '42',
          email: 'ada@example.com',
          name: 'Ada',
          provider: 'google',
        ),
        token: token,
      ).toJson(),
    ),
  );

  test('PKCE verifier and S256 challenge follow RFC 7636', () {
    final pkce = Pkce.generate();
    expect(pkce.verifier.length, inInclusiveRange(43, 128));
    expect(pkce.verifier, matches(RegExp(r'^[A-Za-z0-9\-._~]+$')));
    final expected = base64UrlEncode(
      sha256.convert(ascii.encode(pkce.verifier)).bytes,
    ).replaceAll('=', '');
    expect(pkce.challenge, expected);
    expect(pkce.challenge, isNot(contains('=')));
    expect(Pkce.generate().verifier, isNot(pkce.verifier));
  });

  test(
    'sign in through the loopback redirect and store session in vault',
    () async {
      final vault = InMemoryVault();
      final exchanger = FakeExchanger();
      final client = HttpClient();
      final r = repo(
        vault,
        exchanger,
        opener: (url) async {
          // Simulate the browser: Google redirects back to the loopback URI.
          final redirect = Uri.parse(url.queryParameters['redirect_uri']!);
          expect(url.queryParameters['code_challenge_method'], 'S256');
          expect(url.queryParameters['scope'], 'openid email profile');
          final callback = redirect.replace(
            queryParameters: {
              'code': 'abc',
              'state': url.queryParameters['state'],
            },
          );
          unawaited(
            Future<void>(() async {
              final req = await client.getUrl(callback);
              await (await req.close()).drain<void>();
            }),
          );
          return true;
        },
      );
      final session = await r.signIn();
      client.close();
      expect(session.account.email, 'ada@example.com');
      expect(session.token.accessToken, 'access-abc');
      expect(await vault.read(VaultKeys.googleSession), contains('access-abc'));

      await r.signOut();
      expect(await vault.read(VaultKeys.googleSession), isNull);
      expect(exchanger.revoked, ['refresh-1']);
    },
  );

  test('restore keeps a valid session without network calls', () async {
    final vault = InMemoryVault();
    final exchanger = FakeExchanger();
    await store(
      vault,
      OAuth2Token(
        accessToken: 'a',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
      ),
    );
    final s = await repo(vault, exchanger).restore();
    expect(s!.account.name, 'Ada');
    expect(exchanger.refreshes, 0);
  });

  test('restore refreshes expired sessions', () async {
    final vault = InMemoryVault();
    final exchanger = FakeExchanger();
    await store(
      vault,
      OAuth2Token(
        accessToken: 'old',
        refreshToken: 'r',
        expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
      ),
    );
    final s = await repo(vault, exchanger).restore();
    expect(s!.token.accessToken, 'refreshed');
    expect(s.account.name, 'Ada Lovelace');
  });

  test(
    'restore signs out when refresh is rejected, stays offline on network errors',
    () async {
      final expired = OAuth2Token(
        accessToken: 'old',
        refreshToken: 'r',
        expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
      );

      final vault = InMemoryVault();
      await store(vault, expired);
      final rejected = FakeExchanger()
        ..refreshError = const AuthFailure(AuthFailureKind.expired, 'expired');
      expect(await repo(vault, rejected).restore(), isNull);
      expect(await vault.read(VaultKeys.googleSession), isNull);

      final vault2 = InMemoryVault();
      await store(vault2, expired);
      final offline = FakeExchanger()
        ..refreshError = const AuthFailure(AuthFailureKind.network, 'offline');
      final s = await repo(vault2, offline).restore();
      expect(s!.offline, isTrue);
    },
  );

  test('unconfigured sign-in fails with guidance', () async {
    final r = GoogleAuthRepository(
      config: AppConfig.fromEnvironment(),
      client: OAuth2Client(logger: AppLogger(sinks: [])),
      vault: InMemoryVault(),
      logger: AppLogger(sinks: []),
      openUrl: (_) async => true,
    );
    expect(
      r.signIn(),
      throwsA(
        isA<AuthFailure>().having(
          (f) => f.kind,
          'kind',
          AuthFailureKind.notConfigured,
        ),
      ),
    );
  });
}
