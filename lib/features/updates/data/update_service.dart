import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../../../core/constants/app_constants.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/utils/json_read.dart';
import '../domain/app_release.dart';

/// Which download in a release belongs to this computer.
enum UpdatePlatform {
  macos,
  windows;

  static UpdatePlatform? get current => Platform.isMacOS
      ? macos
      : Platform.isWindows
      ? windows
      : null;

  bool matches(String assetName) {
    final name = assetName.toLowerCase();
    return switch (this) {
      macos => name.endsWith('-macos.dmg'),
      windows => name.startsWith('vesper-setup-') && name.endsWith('.exe'),
    };
  }
}

/// Finds and downloads Vesper releases published on GitHub. The repository
/// is public, so no token is needed.
class UpdateService {
  UpdateService({
    required this.platform,
    Dio? dio,
    this.apiBaseUrl = 'https://api.github.com',
    this.repository = AppConstants.updateRepository,
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 20),
               receiveTimeout: const Duration(minutes: 5),
               validateStatus: (_) => true,
               headers: {'User-Agent': AppConstants.userAgent},
             ),
           );

  final UpdatePlatform platform;
  final String apiBaseUrl;
  final String repository;
  final Dio _dio;

  /// The latest published (non-draft, non-prerelease) release, or null when
  /// there is none or it has no download for this platform.
  Future<AppRelease?> latest() async {
    final Response<String> res;
    try {
      res = await _dio.get<String>(
        '$apiBaseUrl/repos/$repository/releases/latest',
        options: Options(
          responseType: ResponseType.plain,
          headers: {'Accept': 'application/vnd.github+json'},
        ),
      );
    } on DioException catch (e) {
      throw UpdateFailure(
        'Could not check for updates. Check your internet connection.',
        debugDetail: '$e',
      );
    }
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw UpdateFailure(
        'Could not check for updates (GitHub returned ${res.statusCode}).',
      );
    }
    final json = jsonDecode(res.data ?? '{}') as JsonMap;
    final asset = json
        .list('assets')
        .whereType<JsonMap>()
        .where((a) => platform.matches(a.str('name')))
        .firstOrNull;
    if (asset == null) return null;
    return AppRelease(
      version: json.str('tag_name').replaceFirst(RegExp('^[vV]'), ''),
      notes: json.str('body'),
      pageUrl: json.str('html_url'),
      assetName: asset.str('name'),
      assetUrl: asset.str('browser_download_url'),
      assetSize: asset.integer('size'),
    );
  }

  /// Downloads the release's package into [directory], reporting progress
  /// from 0 to 1.
  Future<File> download(
    AppRelease release,
    Directory directory, {
    void Function(double progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    await directory.create(recursive: true);
    final file = File(p.join(directory.path, p.basename(release.assetName)));
    final partial = File('${file.path}.part');
    try {
      final res = await _dio.download(
        release.assetUrl,
        partial.path,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          final size = total > 0 ? total : release.assetSize;
          if (size > 0) onProgress?.call((received / size).clamp(0, 1));
        },
      );
      if (res.statusCode != 200) {
        throw UpdateFailure(
          'Could not download the update (HTTP ${res.statusCode}).',
        );
      }
    } on DioException catch (e) {
      if (partial.existsSync()) await partial.delete();
      throw UpdateFailure(
        CancelToken.isCancel(e)
            ? 'Download cancelled.'
            : 'Could not download the update. Check your internet connection.',
        debugDetail: '$e',
      );
    }
    final length = await partial.length();
    if (release.assetSize > 0 && length != release.assetSize) {
      await partial.delete();
      throw const UpdateFailure(
        'The downloaded update is incomplete. Please try again.',
      );
    }
    if (file.existsSync()) await file.delete();
    return partial.rename(file.path);
  }
}
