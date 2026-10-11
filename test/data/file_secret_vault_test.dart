import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/core/security/file_secret_vault.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('vesper_vault'));
  tearDown(() => dir.deleteSync(recursive: true));

  test(
    'stores secrets encrypted and reads them back after a restart',
    () async {
      final vault = FileSecretVault(dir);
      await vault.write('vesper.request.r1.auth.token', 'top-secret-token');
      await vault.write('vesper.auth.google.session', '{"a":1}');
      await vault.delete('vesper.auth.google.session');

      final raw = File('${dir.path}/secrets.vault').readAsBytesSync();
      expect(String.fromCharCodes(raw), isNot(contains('top-secret-token')));

      final reopened = FileSecretVault(dir);
      expect(await reopened.readAll(), {
        'vesper.request.r1.auth.token': 'top-secret-token',
      });
      await reopened.deleteWhere((k) => k.startsWith('vesper.request.'));
      expect(await FileSecretVault(dir).readAll(), isEmpty);
    },
  );

  test('files are readable only by the user', () async {
    await FileSecretVault(dir).write('k', 'v');
    for (final name in ['secrets.vault', 'secrets.key']) {
      final mode = File('${dir.path}/$name').statSync().modeString();
      expect(mode, 'rw-------', reason: name);
    }
  }, skip: Platform.isWindows);

  test('a vault without its key starts empty instead of failing', () async {
    await FileSecretVault(dir).write('k', 'v');
    File('${dir.path}/secrets.key').deleteSync();
    final vault = FileSecretVault(dir);
    expect(await vault.readAll(), isEmpty);
    await vault.write('k2', 'v2');
    expect(await FileSecretVault(dir).read('k2'), 'v2');
  });

  test('concurrent writes keep every entry', () async {
    final vault = FileSecretVault(dir);
    await Future.wait([for (var i = 0; i < 20; i++) vault.write('k$i', '$i')]);
    expect(await FileSecretVault(dir).readAll(), hasLength(20));
  });
}
