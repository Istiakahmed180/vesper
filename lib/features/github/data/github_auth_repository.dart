import 'dart:convert';

import '../../../core/config/app_config.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/security/secret_vault.dart';
import '../../../core/utils/json_read.dart';
import '../domain/github_models.dart';
import 'github_api.dart';

/// Connects a GitHub account with the OAuth Device Flow, which needs only a
/// public client ID — no client secret ships with the app. Tokens are kept in
/// the OS vault.
class GitHubAuthRepository {
  GitHubAuthRepository({
    required this.api,
    required this.vault,
    required this.config,
    required this.logger,
  });

  final GitHubApi api;
  final SecretVault vault;
  final AppConfig config;
  final AppLogger logger;

  bool get isConfigured => config.isGitHubConfigured;

  void _ensureConfigured() {
    if (!isConfigured) {
      throw const AuthFailure(
        AuthFailureKind.notConfigured,
        'GitHub is not configured. Set GITHUB_CLIENT_ID (see docs/github-integration.md).',
      );
    }
  }

  Future<GitHubSession?> readStored() async {
    final raw = await vault.read(VaultKeys.githubSession);
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final session = GitHubSession.fromJson(json.cast<String, Object?>());
      return session.accessToken.isEmpty ? null : session;
    } catch (_) {
      return null;
    }
  }

  /// Restores the stored session and verifies the token is still valid.
  /// Network failures keep the session (offline use); revoked tokens clear it.
  Future<GitHubSession?> restore() async {
    final stored = await readStored();
    if (stored == null) return null;
    try {
      final account = await api.currentUser(stored.accessToken);
      final refreshed = GitHubSession(
        accessToken: stored.accessToken,
        account: account,
        scopes: stored.scopes,
        refreshToken: stored.refreshToken,
        expiresAt: stored.expiresAt,
      );
      await _store(refreshed);
      return refreshed;
    } on AuthFailure catch (f) {
      if (f.kind == AuthFailureKind.expired) {
        logger.info('GitHub session no longer valid; disconnecting');
        await vault.delete(VaultKeys.githubSession);
        return null;
      }
      return stored;
    } on SyncFailure {
      return stored;
    }
  }

  Future<DeviceCode> startDeviceFlow() {
    _ensureConfigured();
    return api.requestDeviceCode(
      clientId: config.githubClientId,
      scopes: config.githubScopes,
    );
  }

  Future<GitHubSession> completeDeviceFlow(
    DeviceCode code, {
    Future<void>? cancelled,
  }) async {
    _ensureConfigured();
    final json = await api.pollForToken(
      clientId: config.githubClientId,
      code: code,
      cancelled: cancelled,
    );
    final token = json.str('access_token');
    final account = await api.currentUser(token);
    final expiresIn = json.intOrNull('expires_in');
    final session = GitHubSession(
      accessToken: token,
      account: account,
      scopes: json.str('scope'),
      refreshToken: json.strOrNull('refresh_token'),
      expiresAt: expiresIn == null
          ? null
          : DateTime.now().add(Duration(seconds: expiresIn)),
    );
    await _store(session);
    logger.info('GitHub account connected', {'login': account.login});
    return session;
  }

  Future<void> _store(GitHubSession session) =>
      vault.write(VaultKeys.githubSession, jsonEncode(session.toJson()));

  /// Removes the local token. Revoking the grant itself requires the app's
  /// client secret, so users are pointed to GitHub settings for that.
  Future<void> disconnect() async {
    await vault.delete(VaultKeys.githubSession);
    logger.info('GitHub account disconnected');
  }

  Future<String> requireToken() async {
    final session = await readStored();
    if (session == null) {
      throw const AuthFailure(
        AuthFailureKind.notConfigured,
        'Connect your GitHub account first.',
      );
    }
    if (session.isExpired) {
      throw const AuthFailure(
        AuthFailureKind.expired,
        'GitHub authorization expired. Please reconnect your account.',
      );
    }
    return session.accessToken;
  }
}
