/// A published Vesper release with the download for this platform.
class AppRelease {
  const AppRelease({
    required this.version,
    required this.notes,
    required this.pageUrl,
    required this.assetName,
    required this.assetUrl,
    required this.assetSize,
  });

  /// Version without the leading "v", e.g. `0.2.0`.
  final String version;

  /// Release notes (Markdown) as written on GitHub.
  final String notes;
  final String pageUrl;
  final String assetName;
  final String assetUrl;
  final int assetSize;

  bool isNewerThan(String current) => compareVersions(version, current) > 0;
}

/// Compares dotted versions numerically (`0.10.0` > `0.9.2`). A leading "v"
/// and any pre-release or build suffix (`-beta`, `+3`) are ignored.
int compareVersions(String a, String b) {
  List<int> parts(String v) {
    final core = v
        .trim()
        .replaceFirst(RegExp('^[vV]'), '')
        .split(RegExp(r'[-+]'))[0];
    return [for (final p in core.split('.')) int.tryParse(p) ?? 0];
  }

  final x = parts(a);
  final y = parts(b);
  for (var i = 0; i < x.length || i < y.length; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d.sign;
  }
  return 0;
}
