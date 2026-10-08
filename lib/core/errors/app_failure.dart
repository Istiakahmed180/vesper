/// Human readable failures surfaced to the UI. Diagnostic details stay in
/// [debugDetail] (scrubbed before logging) and are never shown by default.
sealed class AppFailure implements Exception {
  const AppFailure(this.message, {this.debugDetail});

  final String message;
  final String? debugDetail;

  String get title;

  @override
  String toString() => '$runtimeType: $message';
}

enum NetworkFailureKind {
  invalidUrl,
  connectionTimeout,
  sendTimeout,
  receiveTimeout,
  dnsFailure,
  connectionRefused,
  connectionReset,
  ssl,
  cancelled,
  tooManyRedirects,
  fileNotFound,
  unknown,
}

class NetworkFailure extends AppFailure {
  const NetworkFailure(this.kind, super.message, {super.debugDetail});

  final NetworkFailureKind kind;

  @override
  String get title => switch (kind) {
    NetworkFailureKind.invalidUrl => 'Invalid URL',
    NetworkFailureKind.connectionTimeout ||
    NetworkFailureKind.sendTimeout ||
    NetworkFailureKind.receiveTimeout => 'Request timed out',
    NetworkFailureKind.dnsFailure => 'Host not found',
    NetworkFailureKind.connectionRefused => 'Connection refused',
    NetworkFailureKind.connectionReset => 'Connection lost',
    NetworkFailureKind.ssl => 'SSL error',
    NetworkFailureKind.cancelled => 'Request cancelled',
    NetworkFailureKind.tooManyRedirects => 'Too many redirects',
    NetworkFailureKind.fileNotFound => 'File not found',
    NetworkFailureKind.unknown => 'Request failed',
  };
}

class ValidationFailure extends AppFailure {
  const ValidationFailure(super.message, {super.debugDetail});

  @override
  String get title => 'Invalid input';
}

class StorageFailure extends AppFailure {
  const StorageFailure(super.message, {super.debugDetail});

  @override
  String get title => 'Storage error';
}

class ImportFailure extends AppFailure {
  const ImportFailure(super.message, {super.debugDetail});

  @override
  String get title => 'Import failed';
}

enum AuthFailureKind {
  notConfigured,
  cancelled,
  denied,
  expired,
  network,
  invalidResponse,
}

class AuthFailure extends AppFailure {
  const AuthFailure(this.kind, super.message, {super.debugDetail});

  final AuthFailureKind kind;

  @override
  String get title => switch (kind) {
    AuthFailureKind.notConfigured => 'Not configured',
    AuthFailureKind.cancelled => 'Sign-in cancelled',
    AuthFailureKind.denied => 'Access denied',
    AuthFailureKind.expired => 'Session expired',
    AuthFailureKind.network => 'Network error',
    AuthFailureKind.invalidResponse => 'Unexpected response',
  };
}

class SyncFailure extends AppFailure {
  const SyncFailure(super.message, {super.debugDetail});

  @override
  String get title => 'Sync failed';
}

class UnexpectedFailure extends AppFailure {
  const UnexpectedFailure([
    super.message = 'Something went wrong. Please try again.',
  ]) : super();

  @override
  String get title => 'Unexpected error';
}

extension FailureMessage on Object {
  /// Converts any thrown object into a message safe to show users.
  String get userMessage => switch (this) {
    final AppFailure f => f.message,
    _ => const UnexpectedFailure().message,
  };
}
