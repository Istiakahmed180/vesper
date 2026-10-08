import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/core/config/app_config.dart';
import 'package:vesper/core/errors/app_failure.dart';
import 'package:vesper/core/logging/app_logger.dart';
import 'package:vesper/core/security/secret_vault.dart';
import 'package:vesper/features/github/data/github_api.dart';
import 'package:vesper/features/github/data/github_auth_repository.dart';
import 'package:vesper/features/github/domain/github_models.dart';

import '../support/fake_github.dart';

void main() {
  final fake = FakeGitHub();
  late GitHubApi api;
  setUpAll(fake.start);
  tearDownAll(() => fake.server.close(force: true));
  setUp(
    () => api = GitHubApi(
      logger: AppLogger(sinks: []),
      baseUrl: fake.url,
      oauthBaseUrl: fake.url,
    ),
  );

  test('device flow connects and stores the token in the vault', () async {
    fake.tokenPolls = 0;
    final vault = InMemoryVault();
    final repo = GitHubAuthRepository(
      api: api,
      vault: vault,
      logger: AppLogger(sinks: []),
      config: const AppConfig(
        googleClientId: '',
        googleDesktopClientSecret: '',
        authBackendUrl: '',
        githubClientId: 'client',
        githubScopes: 'read:user repo',
        apiBaseUrl: '',
      ),
    );
    final code = await repo.startDeviceFlow();
    expect(code.userCode, 'ABCD-1234');
    final session = await repo.completeDeviceFlow(code);
    expect(session.account.login, 'octo');
    expect(fake.tokenPolls, 2);
    expect(await vault.read(VaultKeys.githubSession), contains('gho_valid'));

    expect((await repo.restore())!.account.name, 'Octo Cat');
    await repo.disconnect();
    expect(await vault.read(VaultKeys.githubSession), isNull);
  });

  test('revoked tokens disconnect on restore', () async {
    final vault = InMemoryVault();
    await vault.write(
      VaultKeys.githubSession,
      jsonEncode(
        const GitHubSession(
          accessToken: 'revoked',
          account: GitHubAccount(
            login: 'octo',
            name: '',
            avatarUrl: '',
            htmlUrl: '',
          ),
        ).toJson(),
      ),
    );
    final repo = GitHubAuthRepository(
      api: api,
      vault: vault,
      logger: AppLogger(sinks: []),
      config: AppConfig.fromEnvironment(),
    );
    expect(await repo.restore(), isNull);
    expect(await vault.read(VaultKeys.githubSession), isNull);
  });

  test('unconfigured client id gives a readable error', () async {
    final repo = GitHubAuthRepository(
      api: api,
      vault: InMemoryVault(),
      logger: AppLogger(sinks: []),
      config: AppConfig.fromEnvironment(),
    );
    expect(repo.startDeviceFlow, throwsA(isA<AuthFailure>()));
  });

  test('device flow disabled error', () async {
    expect(
      api.requestDeviceCode(clientId: 'disabled', scopes: 'repo'),
      throwsA(
        isA<AuthFailure>().having(
          (f) => f.message,
          'message',
          contains('Device flow is disabled'),
        ),
      ),
    );
  });

  test('lists repositories across pages', () async {
    final repos = await api.listRepos('gho_valid');
    expect(repos.length, 105);
    expect(repos.first.canPush, isTrue);
  });

  test('401 maps to an expired authorization failure', () async {
    expect(
      api.currentUser('bad'),
      throwsA(
        isA<AuthFailure>().having(
          (f) => f.kind,
          'kind',
          AuthFailureKind.expired,
        ),
      ),
    );
  });

  test('contents API create, read, update and conflict', () async {
    const path = 'api-client/collections/users.json';
    expect(await api.getFile('gho_valid', 'octo/api', 'main', path), isNull);
    final sha = await api.putFile(
      'gho_valid',
      'octo/api',
      'main',
      path,
      content: '{"a":1}',
      message: 'add',
    );
    final file = await api.getFile('gho_valid', 'octo/api', 'main', path);
    expect(file!.content, '{"a":1}');
    expect(file.sha, sha);
    final sha2 = await api.putFile(
      'gho_valid',
      'octo/api',
      'main',
      path,
      content: '{"a":2}',
      message: 'u',
      sha: sha,
    );
    expect(sha2, isNot(sha));
    expect(
      api.putFile(
        'gho_valid',
        'octo/api',
        'main',
        path,
        content: 'x',
        message: 'u',
        sha: sha,
      ),
      throwsA(isA<RemoteConflict>()),
    );
    final listing = await api.listDirectory(
      'gho_valid',
      'octo/api',
      'main',
      'api-client/collections',
    );
    expect(listing.single.path, path);
  });
}
