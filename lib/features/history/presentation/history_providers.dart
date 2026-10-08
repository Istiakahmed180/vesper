import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../domain/history_models.dart';

final historyProvider = StreamProvider<List<HistoryEntry>>(
  (ref) => ref.watch(historyRepositoryProvider).watch(),
);
