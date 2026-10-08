import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/core/security/secret_vault.dart';

/// Behaves like flutter_secure_storage on the macOS legacy keychain:
/// single-item operations work, `readAll` fails with errSecParam (-50).
class LegacyKeychainStorage implements FlutterSecureStorage {
  final values = <String, String>{};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    await Future<void>.delayed(Duration.zero);
    return values[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    await Future<void>.delayed(Duration.zero);
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    await Future<void>.delayed(Duration.zero);
    values.remove(key);
  }

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values.isEmpty
      ? {}
      : throw PlatformException(
          code: 'Unexpected security result code',
          message: 'Code: -50',
        );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('enumerates and deletes without the failing readAll', () async {
    final storage = LegacyKeychainStorage();
    final vault = SecureStorageVault(storage);
    await vault.write(VaultKeys.requestAuth('r1', 'token'), 'a');
    await vault.write(VaultKeys.requestAuth('r2', 'token'), 'b');
    await vault.write(VaultKeys.envVariable('e1', 'v1'), 'c');

    expect(await vault.readAll(), {
      VaultKeys.requestAuth('r1', 'token'): 'a',
      VaultKeys.requestAuth('r2', 'token'): 'b',
      VaultKeys.envVariable('e1', 'v1'): 'c',
    });

    await vault.deleteWhere((k) => k.startsWith(VaultKeys.requestPrefix('r1')));
    expect(
      storage.values.containsKey(VaultKeys.requestAuth('r1', 'token')),
      isFalse,
    );
    expect((await vault.readAll()).length, 2);

    await vault.delete(VaultKeys.envVariable('e1', 'v1'));
    expect((await vault.readAll()).keys, [
      VaultKeys.requestAuth('r2', 'token'),
    ]);

    await vault.clear();
    expect(storage.values, isEmpty, reason: 'index entry removed too');
  });

  test('concurrent writes keep every key in the index', () async {
    final vault = SecureStorageVault(LegacyKeychainStorage());
    await Future.wait([
      for (var i = 0; i < 25; i++) vault.write('vesper.k$i', 'v$i'),
    ]);
    expect((await vault.readAll()).length, 25);
  });
}
