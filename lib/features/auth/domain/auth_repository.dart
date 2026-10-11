import 'auth_models.dart';

/// Provider-agnostic sign-in. Implementations persist sessions in the OS
/// vault and never expose tokens to logs.
abstract class AuthRepository {
  bool get isConfigured;

  /// Restores a stored session, refreshing tokens if needed. Returns null when
  /// signed out. Network failures keep the cached session (`offline: true`).
  Future<AuthSession?> restore();

  /// Interactive sign-in. [cancelled] completes when the user aborts.
  Future<AuthSession> signIn({Future<void>? cancelled});

  Future<void> signOut();

  /// A currently valid OpenID Connect ID token for the signed-in account,
  /// refreshing the session when needed (used to sign in to cloud sync).
  /// Null when signed out or the provider issued none.
  Future<String?> currentIdToken();
}
