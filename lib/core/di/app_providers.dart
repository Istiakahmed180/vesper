import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/api_client/data/cookie_store.dart';
import '../../features/api_client/data/dio_http_client.dart';
import '../../features/api_client/domain/repositories/http_client_port.dart';
import '../../features/collections/data/drift_collection_repository.dart';
import '../../features/collections/domain/collection_repository.dart';
import '../../features/environments/data/drift_environment_repository.dart';
import '../../features/environments/domain/environment_repository.dart';
import '../../features/history/data/drift_history_repository.dart';
import '../../features/history/domain/history_repository.dart';
import '../../features/settings/data/settings_repository.dart';
import '../config/app_config.dart';
import '../logging/app_logger.dart';
import '../oauth/oauth2_client.dart';
import '../security/secret_vault.dart';
import '../storage/app_database.dart';

/// Composition root. Infrastructure providers are overridden in `main.dart`
/// (real database, vault, logger) and in tests (in-memory implementations).

final appConfigProvider = Provider<AppConfig>(
  (ref) => AppConfig.fromEnvironment(),
);

final loggerProvider = Provider<AppLogger>((ref) => AppLogger());

final databaseProvider = Provider<AppDatabase>(
  (ref) => throw UnimplementedError('databaseProvider must be overridden'),
);

final vaultProvider = Provider<SecretVault>((ref) => SecureStorageVault());

/// Whether a native (macOS) menu bar handles keyboard shortcuts.
final nativeMenusProvider = Provider<bool>((ref) => false);

final cookieStoreProvider = Provider<CookieStore>((ref) {
  final store = CookieStore();
  ref.onDispose(store.dispose);
  return store;
});

final httpClientProvider = Provider<HttpClientPort>((ref) {
  final client = DioHttpClient(
    logger: ref.watch(loggerProvider),
    cookies: ref.watch(cookieStoreProvider),
  );
  ref.onDispose(client.dispose);
  return client;
});

final collectionRepositoryProvider = Provider<CollectionRepository>(
  (ref) => DriftCollectionRepository(
    ref.watch(databaseProvider),
    ref.watch(vaultProvider),
  ),
);

final environmentRepositoryProvider = Provider<EnvironmentRepository>(
  (ref) => DriftEnvironmentRepository(
    ref.watch(databaseProvider),
    ref.watch(vaultProvider),
  ),
);

final historyRepositoryProvider = Provider<HistoryRepository>(
  (ref) => DriftHistoryRepository(ref.watch(databaseProvider)),
);

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => SettingsRepository(ref.watch(databaseProvider)),
);

final oauth2ClientProvider = Provider<OAuth2Client>(
  (ref) => OAuth2Client(logger: ref.watch(loggerProvider)),
);
