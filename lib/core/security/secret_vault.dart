import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Abstraction over the OS credential store (macOS Keychain, Windows
/// Credential Manager / DPAPI). Everything sensitive goes through here; the
/// SQLite database only ever stores references.
abstract class SecretVault {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
  Future<Map<String, String>> readAll();
  Future<void> deleteWhere(bool Function(String key) test);
  Future<void> clear();
}

/// Key naming used across the app so vault entries can be cleaned up when the
/// owning record is deleted.
class VaultKeys {
  const VaultKeys._();

  static const prefix = 'vesper.';

  static String requestAuth(String requestId, String field) =>
      '${prefix}request.$requestId.auth.$field';
  static String requestPrefix(String requestId) =>
      '${prefix}request.$requestId.';
  static String envVariable(String environmentId, String variableId) =>
      '${prefix}env.$environmentId.var.$variableId';
  static String environmentPrefix(String environmentId) =>
      '${prefix}env.$environmentId.';
  static const googleSession = '${prefix}auth.google.session';
  static const githubSession = '${prefix}auth.github.session';
}

class SecureStorageVault implements SecretVault {
  SecureStorageVault([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            // The legacy file-based keychain works for unsigned/ad-hoc builds;
            // the data-protection keychain requires a provisioning profile with
            // keychain-access-groups. See docs/security.md.
            mOptions: MacOsOptions(
              usesDataProtectionKeychain: false,
              accountName: 'co.tdevs.vesper',
            ),
            wOptions: WindowsOptions(),
          );

  final FlutterSecureStorage _storage;

  /// Keychain entry listing every key this vault has stored. The plugin's
  /// `readAll` fails with errSecParam (-50) on the macOS legacy keychain once
  /// any item exists, so enumeration uses this index plus single-item reads.
  static const indexKey = '${VaultKeys.prefix}__index__';

  Future<void> _queue = Future.value();

  /// Serializes index updates so concurrent writes cannot lose keys.
  Future<T> _locked<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<Set<String>> _readIndex() async {
    final raw = await _storage.read(key: indexKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is List ? decoded.whereType<String>().toSet() : {};
    } on FormatException {
      return {};
    }
  }

  Future<void> _writeIndex(Set<String> keys) => keys.isEmpty
      ? _storage.delete(key: indexKey)
      : _storage.write(key: indexKey, value: jsonEncode(keys.toList()..sort()));

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _locked(() async {
    await _storage.write(key: key, value: value);
    final keys = await _readIndex();
    if (keys.add(key)) await _writeIndex(keys);
  });

  @override
  Future<void> delete(String key) => _locked(() async {
    await _storage.delete(key: key);
    final keys = await _readIndex();
    if (keys.remove(key)) await _writeIndex(keys);
  });

  @override
  Future<Map<String, String>> readAll() => _locked(() async {
    final result = <String, String>{};
    for (final key in await _readIndex()) {
      final value = await _storage.read(key: key);
      if (value != null) result[key] = value;
    }
    return result;
  });

  @override
  Future<void> deleteWhere(bool Function(String key) test) => _locked(() async {
    final keys = await _readIndex();
    final doomed = keys.where(test).toList();
    for (final key in doomed) {
      await _storage.delete(key: key);
    }
    if (doomed.isNotEmpty) await _writeIndex(keys..removeAll(doomed));
  });

  @override
  Future<void> clear() => deleteWhere((_) => true);
}

/// Volatile vault used in tests and as a fallback when the OS store fails.
class InMemoryVault implements SecretVault {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);

  @override
  Future<Map<String, String>> readAll() async => Map.of(_values);

  @override
  Future<void> deleteWhere(bool Function(String key) test) async =>
      _values.removeWhere((k, _) => test(k));

  @override
  Future<void> clear() async => _values.clear();
}
