import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase/supabase.dart';

import '../../../core/di/app_providers.dart';
import '../data/supabase_cloud.dart';

/// Supabase client for cloud sync; null when this build has no project.
final cloudClientProvider = Provider<SupabaseClient?>((ref) {
  final config = ref.watch(appConfigProvider);
  if (!config.isCloudConfigured) return null;
  final client = SupabaseClient(
    config.supabaseUrl,
    config.supabaseAnonKey,
    authOptions: AuthClientOptions(pkceAsyncStorage: MemoryAuthStorage()),
  );
  ref.onDispose(client.dispose);
  return client;
});

/// Cloud sign-in shared by cloud sync and GitHub sign-in.
final cloudAuthProvider = Provider<CloudAuth?>((ref) {
  final client = ref.watch(cloudClientProvider);
  if (client == null) return null;
  return CloudAuth(
    client: client,
    vault: ref.watch(vaultProvider),
    logger: ref.watch(loggerProvider),
  );
});
