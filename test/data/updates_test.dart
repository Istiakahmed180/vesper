import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/core/constants/app_constants.dart';
import 'package:vesper/core/errors/app_failure.dart';
import 'package:vesper/features/updates/data/update_installer.dart';
import 'package:vesper/features/updates/data/update_service.dart';
import 'package:vesper/features/updates/domain/app_release.dart';
import 'package:vesper/features/updates/presentation/update_controller.dart';

/// Serves a fake GitHub "latest release" and its downloads.
class _ReleaseServer {
  _ReleaseServer._(this._server);
  final HttpServer _server;

  String tag = 'v0.3.0';
  int status = 200;
  final package = utf8.encode('fake package contents' * 100);
  int? advertisedSize;

  static Future<_ReleaseServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final s = _ReleaseServer._(server);
    server.listen(s._handle);
    return s;
  }

  String get base => 'http://127.0.0.1:${_server.port}';

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    if (req.uri.path == '/repos/team/vesper/releases/latest') {
      res.statusCode = status;
      res.headers.contentType = ContentType.json;
      res.write(
        jsonEncode({
          'tag_name': tag,
          'body': '* Faster requests',
          'html_url': '$base/releases/$tag',
          'assets': [
            for (final name in [
              'Vesper-0.3.0-macOS.dmg',
              'Vesper-Setup-0.3.0.exe',
            ])
              {
                'name': name,
                'size': advertisedSize ?? package.length,
                'browser_download_url': '$base/download/$name',
              },
          ],
        }),
      );
    } else if (req.uri.path.startsWith('/download/')) {
      res.add(package);
    } else {
      res.statusCode = 404;
    }
    await res.close();
  }
}

class _FakeInstaller implements UpdateInstaller {
  File? installed;
  File? opened;
  Object? failWith;

  @override
  Future<void> install(File package) async {
    if (failWith != null) throw failWith!;
    installed = package;
  }

  @override
  Future<void> openManually(File package) async => opened = package;
}

void main() {
  test('versions compare numerically', () {
    expect(compareVersions('0.10.0', '0.9.2'), 1);
    expect(compareVersions('v1.2', '1.2.0'), 0);
    expect(compareVersions('1.2.0+5', '1.2.0'), 0);
    expect(compareVersions('1.2.0', '1.2.1-beta'), -1);
  });

  test('the app version matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(
      r'^version:\s*([^+\s]+)',
      multiLine: true,
    ).firstMatch(pubspec)!.group(1);
    expect(AppConstants.appVersion, version);
  });

  group('with a release server', () {
    late _ReleaseServer server;
    late Directory temp;

    setUp(() async {
      server = await _ReleaseServer.start();
      temp = await Directory.systemTemp.createTemp('vesper-update-test');
    });

    tearDown(() async {
      await server.close();
      await temp.delete(recursive: true);
    });

    UpdateService service(UpdatePlatform platform) => UpdateService(
      platform: platform,
      apiBaseUrl: server.base,
      repository: 'team/vesper',
    );

    test('finds the download for each platform', () async {
      final mac = await service(UpdatePlatform.macos).latest();
      expect(mac!.version, '0.3.0');
      expect(mac.assetName, 'Vesper-0.3.0-macOS.dmg');
      expect(mac.notes, '* Faster requests');
      final win = await service(UpdatePlatform.windows).latest();
      expect(win!.assetName, 'Vesper-Setup-0.3.0.exe');

      server.status = 404;
      expect(await service(UpdatePlatform.macos).latest(), isNull);
      server.status = 500;
      await expectLater(
        service(UpdatePlatform.macos).latest(),
        throwsA(isA<UpdateFailure>()),
      );
    });

    test('downloads with progress and rejects incomplete files', () async {
      final s = service(UpdatePlatform.macos);
      final release = (await s.latest())!;
      final progress = <double>[];
      final file = await s.download(release, temp, onProgress: progress.add);
      expect(await file.readAsBytes(), server.package);
      expect(file.path.endsWith('Vesper-0.3.0-macOS.dmg'), isTrue);
      expect(progress.last, 1);

      server.advertisedSize = server.package.length + 1;
      final wrong = (await s.latest())!;
      await expectLater(s.download(wrong, temp), throwsA(isA<UpdateFailure>()));
    });

    ProviderContainer container(_FakeInstaller installer, List<bool> quits) {
      final c = ProviderContainer(
        overrides: [
          currentVersionProvider.overrideWithValue('0.2.0'),
          autoUpdateSupportedProvider.overrideWithValue(false),
          updateServiceProvider.overrideWithValue(
            service(UpdatePlatform.macos),
          ),
          updateInstallerProvider.overrideWithValue(installer),
          updateDownloadDirProvider.overrideWithValue(temp),
          quitForUpdateProvider.overrideWithValue(() async => quits.add(true)),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('check, install and quit', () async {
      final installer = _FakeInstaller();
      final quits = <bool>[];
      final c = container(installer, quits);
      final updates = c.read(updateProvider.notifier);

      server.tag = 'v0.2.0';
      await updates.check();
      expect(c.read(updateProvider).phase, UpdatePhase.upToDate);

      server.tag = 'v0.3.0';
      await updates.check();
      expect(c.read(updateProvider).phase, UpdatePhase.available);
      expect(c.read(updateProvider).release!.version, '0.3.0');

      updates.dismiss();
      await updates.check();
      expect(c.read(updateProvider).dismissed, isTrue);
      await updates.check(manual: true);
      expect(c.read(updateProvider).dismissed, isFalse);

      await updates.install();
      expect(installer.installed, isNotNull);
      expect(quits, [true]);
    });

    test('a failed install offers the download instead of quitting', () async {
      final installer = _FakeInstaller()
        ..failWith = const UpdateFailure('No permission');
      final quits = <bool>[];
      final c = container(installer, quits);
      final updates = c.read(updateProvider.notifier);
      await updates.check();
      await updates.install();
      expect(c.read(updateProvider).phase, UpdatePhase.failed);
      expect(c.read(updateProvider).error, 'No permission');
      expect(installer.opened, isNotNull);
      expect(quits, isEmpty);

      server.status = 500;
      await updates.check();
      expect(c.read(updateProvider).phase, UpdatePhase.failed, reason: 'quiet');
      await updates.check(manual: true);
      expect(c.read(updateProvider).error, contains('500'));
    });
  });
}
