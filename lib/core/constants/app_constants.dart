class AppConstants {
  const AppConstants._();

  static const appName = 'Vesper';
  static const appVersion = '0.1.0';
  static const userAgent = 'Vesper/$appVersion';
  static const databaseName = 'vesper';

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
