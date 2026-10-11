import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'core/constants/app_constants.dart';
import 'core/di/app_providers.dart';
import 'core/logging/app_logger.dart';
import 'core/storage/app_database.dart';
import 'core/storage/vault_migration.dart';
import 'features/history/data/drift_history_repository.dart';
import 'features/settings/data/settings_repository.dart';
import 'features/settings/presentation/settings_controller.dart';
import 'features/workspace/presentation/app_shell.dart';
import 'features/workspace/presentation/workspace_controller.dart';
import 'features/workspaces/presentation/workspace_providers.dart';

const minimumWindowSize = Size(980, 620);

/// Application startup shared by `main()` and the release-mode verification
/// tests: logging, window, database, settings, history retention and tab
/// restoration.
Future<ProviderContainer> bootstrap({
  bool installErrorHandlers = true,
  List<Override> overrides = const [],
}) async {
  final logger = AppLogger(
    minLevel: kDebugMode ? LogLevel.debug : LogLevel.info,
  );
  final supportDir = await getApplicationSupportDirectory();
  logger.addSink(FileLogSink(Directory(p.join(supportDir.path, 'logs'))));

  if (installErrorHandlers) {
    FlutterError.onError = (details) {
      logger.error(
        'Flutter error',
        error: details.exception,
        stackTrace: details.stack,
      );
      if (kDebugMode) FlutterError.presentError(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      logger.error('Uncaught error', error: error, stackTrace: stack);
      return true;
    };
  }

  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      title: AppConstants.appName,
      size: Size(1440, 900),
      minimumSize: minimumWindowSize,
      center: true,
      backgroundColor: Color(0xFF15171C),
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );

  final database = AppDatabase.open();
  final settingsRepo = SettingsRepository(database);
  final settings = await settingsRepo.loadSettings();
  final savedWorkspace = await settingsRepo.read(
    SettingsRepository.activeWorkspaceKey,
  );
  final workspaceExists =
      savedWorkspace != null &&
      await (database.select(
            database.workspaces,
          )..where((w) => w.id.equals(savedWorkspace))).getSingleOrNull() !=
          null;

  // Apply history retention at startup.
  unawaited(
    DriftHistoryRepository(database)
        .prune(
          retentionDays: settings.historyRetentionDays,
          maxEntries: settings.historyMaxEntries,
        )
        .catchError((Object e) {
          logger.warning('History pruning failed');
          return 0;
        }),
  );

  final container = ProviderContainer(
    overrides: [
      loggerProvider.overrideWithValue(logger),
      databaseProvider.overrideWithValue(database),
      initialSettingsProvider.overrideWithValue(settings),
      initialWorkspaceIdProvider.overrideWithValue(
        workspaceExists ? savedWorkspace : defaultWorkspaceId,
      ),
      nativeMenusProvider.overrideWithValue(Platform.isMacOS),
      windowManagedProvider.overrideWithValue(true),
      ...overrides,
    ],
    // Repositories surface errors to the UI; automatic retries would only
    // repeat failing disk or network operations.
    retry: (_, _) => null,
  );
  await migrateEnvironmentVaultKeys(
    database,
    container.read(vaultProvider),
  ).catchError((Object e) => logger.warning('Vault key migration failed'));
  await container
      .read(workspaceProvider.notifier)
      .restore(settings.startupBehavior);
  logger.info('Application started', {
    'version': AppConstants.appVersion,
    'os': Platform.operatingSystem,
  });
  return container;
}
