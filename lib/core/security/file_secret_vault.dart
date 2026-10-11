import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

import 'secret_vault.dart';

/// Secrets in an AES-256-GCM encrypted file in the app support directory,
/// with the key in a second file; both are readable only by the current user
/// (mode 600).
///
/// Used on macOS instead of the Keychain so the app never asks for keychain
/// access after a rebuild or update. Protection relies on the user account
/// and file permissions rather than on the Keychain; see docs/security.md.
class FileSecretVault implements SecretVault {
  FileSecretVault(Directory directory)
    : _file = File(p.join(directory.path, 'secrets.vault')),
      _keyFile = File(p.join(directory.path, 'secrets.key'));

  final File _file;
  final File _keyFile;
  final _cipher = AesGcm.with256bits();
  Map<String, String>? _cache;
  SecretKey? _key;
  Future<void> _queue = Future.value();

  /// Serializes access so concurrent writes cannot lose entries.
  Future<T> _locked<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<SecretKey> _secretKey() async {
    if (_key case final key?) return key;
    if (_keyFile.existsSync()) {
      final bytes = base64.decode((await _keyFile.readAsString()).trim());
      if (bytes.length == 32) return _key = SecretKey(bytes);
    }
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    await _keyFile.parent.create(recursive: true);
    await _keyFile.writeAsString(base64.encode(bytes), flush: true);
    await _restrict(_keyFile);
    return _key = SecretKey(bytes);
  }

  Future<Map<String, String>> _load() async {
    if (_cache case final cache?) return cache;
    if (!_file.existsSync()) return _cache = {};
    try {
      final box = SecretBox.fromConcatenation(
        await _file.readAsBytes(),
        nonceLength: _cipher.nonceLength,
        macLength: _cipher.macAlgorithm.macLength,
      );
      final clear = await _cipher.decrypt(box, secretKey: await _secretKey());
      final json = jsonDecode(utf8.decode(clear));
      return _cache = {
        if (json is Map)
          for (final MapEntry(:key, :value) in json.entries)
            if (key is String && value is String) key: value,
      };
    } catch (_) {
      // Unreadable (e.g. the key file was removed): keep a copy, start empty.
      await _file.rename('${_file.path}.unreadable');
      return _cache = {};
    }
  }

  Future<void> _save(Map<String, String> values) async {
    _cache = values;
    final box = await _cipher.encrypt(
      utf8.encode(jsonEncode(values)),
      secretKey: await _secretKey(),
    );
    final temp = File('${_file.path}.tmp');
    await temp.parent.create(recursive: true);
    await temp.writeAsBytes(box.concatenation(), flush: true);
    await _restrict(temp);
    await temp.rename(_file.path);
  }

  static Future<void> _restrict(File file) async {
    if (Platform.isWindows) return;
    await Process.run('chmod', ['600', file.path]);
  }

  @override
  Future<String?> read(String key) => _locked(() async => (await _load())[key]);

  @override
  Future<void> write(String key, String value) => _locked(() async {
    final values = {...await _load(), key: value};
    await _save(values);
  });

  @override
  Future<void> delete(String key) => _locked(() async {
    final values = await _load();
    if (!values.containsKey(key)) return;
    await _save({...values}..remove(key));
  });

  @override
  Future<Map<String, String>> readAll() =>
      _locked(() async => Map.of(await _load()));

  @override
  Future<void> deleteWhere(bool Function(String key) test) => _locked(() async {
    final values = await _load();
    if (!values.keys.any(test)) return;
    await _save({...values}..removeWhere((k, _) => test(k)));
  });

  @override
  Future<void> clear() => deleteWhere((_) => true);
}
