import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../domain/app_settings.dart';

/// Initial settings loaded before the first frame (overridden in main).
final initialSettingsProvider = Provider<AppSettings>(
  (ref) => const AppSettings(),
);

final settingsProvider = NotifierProvider<SettingsController, AppSettings>(
  SettingsController.new,
);

class SettingsController extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.watch(initialSettingsProvider);

  void update(AppSettings Function(AppSettings current) change) {
    final next = change(state);
    state = next;
    unawaited(ref.read(settingsRepositoryProvider).saveSettings(next));
  }

  void updateNetwork(
    NetworkSettings Function(NetworkSettings current) change,
  ) => update((s) => s.copyWith(network: change(s.network)));

  void setActiveEnvironment(String? id) =>
      update((s) => s.copyWith(activeEnvironmentId: () => id));
}
