/// Build-time configuration.
///
/// Values are injected with `--dart-define-from-file=.env` (or individual
/// `--dart-define` flags). Nothing secret belongs here: desktop binaries can be
/// inspected, so only public identifiers (OAuth client IDs, URLs) are accepted.
class AppConfig {
  const AppConfig({
    required this.googleClientId,
    required this.googleDesktopClientSecret,
    required this.authBackendUrl,
    required this.githubClientId,
    required this.githubScopes,
    required this.apiBaseUrl,
  });

  factory AppConfig.fromEnvironment() => const AppConfig(
    googleClientId: String.fromEnvironment('GOOGLE_CLIENT_ID'),
    googleDesktopClientSecret: String.fromEnvironment(
      'GOOGLE_DESKTOP_CLIENT_SECRET',
    ),
    authBackendUrl: String.fromEnvironment('AUTH_BACKEND_URL'),
    githubClientId: String.fromEnvironment('GITHUB_CLIENT_ID'),
    githubScopes: String.fromEnvironment(
      'GITHUB_SCOPES',
      defaultValue: 'read:user repo',
    ),
    apiBaseUrl: String.fromEnvironment('API_BASE_URL'),
  );

  /// OAuth client ID of a Google "Desktop app" client.
  final String googleClientId;

  /// Google's installed-app client secret. Google documents this value as
  /// non-confidential for desktop clients; it is optional and only used when no
  /// [authBackendUrl] is configured. See docs/authentication.md.
  final String googleDesktopClientSecret;

  /// Optional backend that performs the Google code exchange server-side.
  final String authBackendUrl;

  /// Client ID of a GitHub OAuth App (or GitHub App) with Device Flow enabled.
  final String githubClientId;

  /// Space separated GitHub scopes.
  final String githubScopes;

  /// Reserved for a future Vesper cloud backend.
  final String apiBaseUrl;

  bool get isGoogleConfigured => googleClientId.isNotEmpty;
  bool get isGitHubConfigured => githubClientId.isNotEmpty;
  bool get hasAuthBackend => authBackendUrl.isNotEmpty;
}
