import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/errors/app_failure.dart';
import 'update_service.dart';

/// Installs a downloaded update. [install] prepares everything and starts a
/// helper that finishes the job once this app has quit, then relaunches it;
/// the caller must quit right after it returns.
abstract interface class UpdateInstaller {
  Future<void> install(File package);

  /// Opens the package the normal way (DMG in Finder, installer wizard),
  /// for when installing in place is not possible.
  Future<void> openManually(File package);

  static UpdateInstaller? forPlatform(UpdatePlatform? platform) =>
      switch (platform) {
        UpdatePlatform.macos => MacUpdateInstaller(),
        UpdatePlatform.windows => WindowsUpdateInstaller(),
        null => null,
      };
}

/// Replaces the running Vesper.app with the one inside the downloaded DMG.
class MacUpdateInstaller implements UpdateInstaller {
  MacUpdateInstaller({String? executable})
    : _executable = executable ?? Platform.resolvedExecutable;

  final String _executable;

  /// `/Applications/Vesper.app` for `/Applications/Vesper.app/Contents/MacOS/Vesper`.
  String get bundlePath => p.dirname(p.dirname(p.dirname(_executable)));

  @override
  Future<void> install(File package) async {
    final target = bundlePath;
    if (!target.endsWith('.app')) {
      throw const UpdateFailure('Vesper is not running from an app bundle.');
    }
    if (!await _canWrite(p.dirname(target))) {
      throw UpdateFailure(
        'Vesper cannot replace itself in ${p.dirname(target)}. '
        'Open the downloaded file and drag Vesper to Applications.',
      );
    }

    final work = await Directory.systemTemp.createTemp('vesper-update-');
    final mount = p.join(work.path, 'mount');
    final staged = p.join(work.path, 'Vesper.app');
    await _run('hdiutil', [
      'attach',
      '-nobrowse',
      '-readonly',
      '-noautoopen',
      '-mountpoint',
      mount,
      package.path,
    ]);
    try {
      final source = Directory(mount)
          .listSync()
          .whereType<Directory>()
          .where((d) => d.path.endsWith('.app'))
          .firstOrNull;
      if (source == null) {
        throw const UpdateFailure('The update does not contain Vesper.app.');
      }
      await _run('ditto', [source.path, staged]);
    } finally {
      await Process.run('hdiutil', ['detach', mount, '-force']);
    }

    // Waits for this process to exit, swaps the bundles (restoring the old
    // one if the copy fails) and starts the new version.
    final script = File(p.join(work.path, 'install.sh'));
    await script.writeAsString('''
#!/bin/bash
TARGET=${_quote(target)}
NEW=${_quote(staged)}
while kill -0 $pid 2>/dev/null; do sleep 0.3; done
rm -rf "\$TARGET.old"
if mv "\$TARGET" "\$TARGET.old" && ditto "\$NEW" "\$TARGET"; then
  rm -rf "\$TARGET.old"
else
  rm -rf "\$TARGET"
  mv "\$TARGET.old" "\$TARGET"
fi
xattr -dr com.apple.quarantine "\$TARGET" 2>/dev/null
open "\$TARGET"
rm -rf ${_quote(work.path)}
''');
    await Process.start('/bin/bash', [
      script.path,
    ], mode: ProcessStartMode.detached);
  }

  @override
  Future<void> openManually(File package) async {
    await Process.run('open', [package.path]);
  }

  static Future<bool> _canWrite(String dir) async {
    try {
      final probe = File(
        p.join(dir, '.vesper-update-${DateTime.now().microsecondsSinceEpoch}'),
      );
      await probe.writeAsString('');
      await probe.delete();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  static String _quote(String s) => "'${s.replaceAll("'", r"'\''")}'";
}

/// Runs the downloaded Inno Setup installer silently; it closes Vesper,
/// upgrades the installation in place and starts the new version.
class WindowsUpdateInstaller implements UpdateInstaller {
  @override
  Future<void> install(File package) async {
    await Process.start(package.path, const [
      '/VERYSILENT',
      '/SUPPRESSMSGBOXES',
      '/NORESTART',
      '/CLOSEAPPLICATIONS',
      '/RELAUNCH=1',
    ], mode: ProcessStartMode.detached);
  }

  @override
  Future<void> openManually(File package) async {
    await Process.start(
      package.path,
      const [],
      mode: ProcessStartMode.detached,
    );
  }
}

Future<void> _run(String executable, List<String> args) async {
  final result = await Process.run(executable, args);
  if (result.exitCode != 0) {
    throw UpdateFailure(
      'Could not prepare the update.',
      debugDetail: '$executable ${args.join(' ')}: ${result.stderr}',
    );
  }
}
