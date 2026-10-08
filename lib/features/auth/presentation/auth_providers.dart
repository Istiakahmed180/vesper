import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/di/app_providers.dart';
import '../data/google_auth_repository.dart';
import '../domain/auth_models.dart';
import '../domain/auth_repository.dart';

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => GoogleAuthRepository(
    config: ref.watch(appConfigProvider),
    client: ref.watch(oauth2ClientProvider),
    vault: ref.watch(vaultProvider),
    logger: ref.watch(loggerProvider),
    openUrl: (url) => launchUrl(url, mode: LaunchMode.externalApplication),
  ),
);

final authSessionProvider = AsyncNotifierProvider<AuthController, AuthSession?>(
  AuthController.new,
);

class AuthController extends AsyncNotifier<AuthSession?> {
  @override
  Future<AuthSession?> build() => ref.watch(authRepositoryProvider).restore();

  Future<void> signIn({Future<void>? cancelled}) async {
    final session = await ref
        .read(authRepositoryProvider)
        .signIn(cancelled: cancelled);
    state = AsyncData(session);
  }

  Future<void> signOut() async {
    await ref.read(authRepositoryProvider).signOut();
    state = const AsyncData(null);
  }
}
