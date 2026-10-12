import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/constants/app_constants.dart';
import '../../../core/di/app_providers.dart';
import '../../../core/errors/app_failure.dart';
import '../../settings/presentation/settings_controller.dart';
import '../data/update_installer.dart';
import '../data/update_service.dart';
import '../domain/app_release.dart';

enum UpdatePhase { idle, checking, upToDate, available, downloading, failed }

@immutable
class UpdateState {
  const UpdateState({
    this.phase = UpdatePhase.idle,
    this.release,
    this.progress = 0,
    this.error,
    this.dismissed = false,
  });

  final UpdatePhase phase;

  /// The newer release, once one was found.
  final AppRelease? release;

  /// Download progress from 0 to 1.
  final double progress;
  final String? error;

  /// "Later" was chosen for [release]; the banner stays hidden for it.
  final bool dismissed;

  bool get busy =>
      phase == UpdatePhase.checking || phase == UpdatePhase.downloading;

  UpdateState copyWith({
    UpdatePhase? phase,
    AppRelease? release,
    double? progress,
    String? error,
    bool? dismissed,
  }) => UpdateState(
    phase: phase ?? this.phase,
    release: release ?? this.release,
    progress: progress ?? this.progress,
    error: error,
    dismissed: dismissed ?? this.dismissed,
  );
}

/// The version this build reports; overridden in tests.
final currentVersionProvider = Provider<String>(
  (ref) => AppConstants.appVersion,
);

final updateServiceProvider = Provider<UpdateService?>((ref) {
  final platform = UpdatePlatform.current;
  return platform == null ? null : UpdateService(platform: platform);
});

final updateInstallerProvider = Provider<UpdateInstaller?>(
  (ref) => UpdateInstaller.forPlatform(UpdatePlatform.current),
);

/// Where downloads are kept until they are installed.
final updateDownloadDirProvider = Provider<Directory>(
  (ref) => Directory(p.join(Directory.systemTemp.path, 'vesper-updates')),
);

/// Whether background checks run (off in debug builds and tests, where an
/// install would replace the development build).
final autoUpdateSupportedProvider = Provider<bool>((ref) => !kDebugMode);

/// Closes the database and exits so the installer can replace the app.
final quitForUpdateProvider = Provider<Future<void> Function()>(
  (ref) => () async {
    await ref.read(loggerProvider).close();
    await ref.read(databaseProvider).close();
    exit(0);
  },
);

final updateProvider = NotifierProvider<UpdateController, UpdateState>(
  UpdateController.new,
);

class UpdateController extends Notifier<UpdateState> {
  static const firstCheckDelay = Duration(seconds: 20);
  static const checkInterval = Duration(hours: 6);

  Timer? _first;
  Timer? _periodic;
  CancelToken? _download;

  @override
  UpdateState build() {
    final auto =
        ref.watch(settingsProvider.select((s) => s.autoUpdate)) &&
        ref.watch(autoUpdateSupportedProvider) &&
        ref.watch(updateServiceProvider) != null;
    if (auto) {
      _first = Timer(firstCheckDelay, () => unawaited(check()));
      _periodic = Timer.periodic(checkInterval, (_) => unawaited(check()));
    }
    ref.onDispose(() {
      _first?.cancel();
      _periodic?.cancel();
    });
    return stateOrNull ?? const UpdateState();
  }

  /// Looks for a newer release. Background checks fail silently; [manual]
  /// checks report errors.
  Future<void> check({bool manual = false}) async {
    final service = ref.read(updateServiceProvider);
    if (service == null || state.busy) return;
    final previous = state;
    state = state.copyWith(phase: UpdatePhase.checking);
    try {
      final release = await service.latest();
      if (release != null &&
          release.isNewerThan(ref.read(currentVersionProvider))) {
        final same = previous.release?.version == release.version;
        state = UpdateState(
          phase: UpdatePhase.available,
          release: release,
          // A manual check shows the banner again even after "Later".
          dismissed: same && previous.dismissed && !manual,
        );
      } else {
        state = const UpdateState(phase: UpdatePhase.upToDate);
      }
    } catch (e) {
      ref.read(loggerProvider).warning('Update check failed', {'error': '$e'});
      state = manual
          ? previous.copyWith(phase: UpdatePhase.failed, error: e.userMessage)
          : previous;
    }
  }

  void dismiss() => state = state.copyWith(dismissed: true);

  void cancelDownload() => _download?.cancel();

  /// Downloads the release, starts the installer and quits. The new version
  /// opens by itself once it is installed.
  Future<void> install() async {
    final release = state.release;
    final service = ref.read(updateServiceProvider);
    final installer = ref.read(updateInstallerProvider);
    if (release == null || service == null || installer == null) return;
    if (state.phase == UpdatePhase.downloading) return;

    _download = CancelToken();
    state = state.copyWith(phase: UpdatePhase.downloading, progress: 0);
    File? package;
    try {
      package = await service.download(
        release,
        ref.read(updateDownloadDirProvider),
        cancelToken: _download,
        onProgress: (v) {
          if (ref.mounted) state = state.copyWith(progress: v);
        },
      );
      ref.read(loggerProvider).info('Installing update ${release.version}');
      await installer.install(package);
    } catch (e) {
      ref.read(loggerProvider).warning('Update failed', {'error': '$e'});
      if (ref.mounted) {
        state = state.copyWith(phase: UpdatePhase.failed, error: e.userMessage);
      }
      // Installing in place is not possible: hand over the download.
      if (package != null) await installer.openManually(package);
      return;
    } finally {
      _download = null;
    }
    await ref.read(quitForUpdateProvider)();
  }
}
