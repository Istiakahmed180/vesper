class AppConstants {
  const AppConstants._();

  static const appName = 'Vesper';

  /// Must match `version:` in pubspec.yaml (checked by a test).
  static const appVersion = '0.2.8';
  static const userAgent = 'Vesper/$appVersion';
  static const databaseName = 'vesper';

  /// GitHub repository whose published releases deliver app updates.
  static const updateRepository = 'Istiakahmed180/vesper';

  static const defaultTimeoutMs = 30000;
  static const defaultMaxRedirects = 10;
  static const defaultHistoryRetentionDays = 30;
  static const defaultHistoryMaxEntries = 1000;

  /// Imported files larger than this are rejected before parsing.
  static const maxImportBytes = 50 * 1024 * 1024;

  /// Response bodies larger than this are not syntax highlighted / folded.
  static const maxPrettyBytes = 25 * 1024 * 1024;

  /// Longest line rendered in the code viewer; longer lines are clipped.
  static const maxRenderedLineLength = 4000;
}
