import 'dart:io';

import 'package:dio/dio.dart';

import '../errors/app_failure.dart';
import '../security/redactor.dart';

/// Maps transport exceptions to human readable [NetworkFailure]s.
class NetworkErrorMapper {
  const NetworkErrorMapper();

  // errno values for macOS/BSD, Linux and Windows (WSA).
  static const _refused = {61, 111, 10061};
  static const _reset = {54, 104, 10054, 32, 10053};
  static const _unreachable = {50, 51, 65, 101, 113, 10050, 10051, 10065};
  static const _timedOut = {60, 110, 10060};

  NetworkFailure map(Object error, {required Duration timeout}) {
    final seconds = _formatSeconds(timeout);
    if (error is NetworkFailure) return error;
    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
          return NetworkFailure(
            NetworkFailureKind.connectionTimeout,
            'Could not connect to the server within $seconds.',
            debugDetail: _detail(error),
          );
        case DioExceptionType.sendTimeout:
          return NetworkFailure(
            NetworkFailureKind.sendTimeout,
            'Sending the request timed out after $seconds.',
            debugDetail: _detail(error),
          );
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.transformTimeout:
          return NetworkFailure(
            NetworkFailureKind.receiveTimeout,
            'Request timed out after $seconds.',
            debugDetail: _detail(error),
          );
        case DioExceptionType.cancel:
          return const NetworkFailure(
            NetworkFailureKind.cancelled,
            'The request was cancelled.',
          );
        case DioExceptionType.badCertificate:
          return NetworkFailure(
            NetworkFailureKind.ssl,
            'SSL certificate verification failed. The server certificate is not trusted. '
            'You can disable verification in Settings → Network for local development.',
            debugDetail: _detail(error),
          );
        case DioExceptionType.connectionError:
        case DioExceptionType.unknown:
        case DioExceptionType.badResponse:
          final inner = error.error;
          if (inner != null && inner is! DioException) {
            return map(inner, timeout: timeout);
          }
          return NetworkFailure(
            NetworkFailureKind.unknown,
            'Unable to connect to server.',
            debugDetail: _detail(error),
          );
      }
    }
    if (error is SocketException) return _socket(error);
    if (error is HandshakeException || error is TlsException) {
      return NetworkFailure(
        NetworkFailureKind.ssl,
        'SSL handshake failed. The server certificate may be invalid, expired or self-signed.',
        debugDetail: _detail(error),
      );
    }
    if (error is RedirectException) {
      return NetworkFailure(
        NetworkFailureKind.tooManyRedirects,
        'Too many redirects. The server keeps redirecting the request.',
        debugDetail: _detail(error),
      );
    }
    if (error is HttpException) {
      return NetworkFailure(
        NetworkFailureKind.connectionReset,
        'The connection was closed before a complete response was received.',
        debugDetail: _detail(error),
      );
    }
    if (error is PathNotFoundException || error is FileSystemException) {
      final path = (error as FileSystemException).path;
      return NetworkFailure(
        NetworkFailureKind.fileNotFound,
        'Could not read the file${path == null ? '' : ' "$path"'}. It may have been moved or deleted.',
      );
    }
    if (error is ArgumentError || error is FormatException) {
      return NetworkFailure(
        NetworkFailureKind.invalidUrl,
        'Invalid URL.',
        debugDetail: _detail(error),
      );
    }
    return NetworkFailure(
      NetworkFailureKind.unknown,
      'The request failed unexpectedly.',
      debugDetail: _detail(error),
    );
  }

  NetworkFailure _socket(SocketException e) {
    final code = e.osError?.errorCode;
    final message = '${e.message} ${e.osError?.message ?? ''}'.toLowerCase();
    if (message.contains('failed host lookup') ||
        message.contains('nodename nor servname') ||
        message.contains('no address associated') ||
        message.contains('name or service not known') ||
        code == 8 ||
        code == 11001 ||
        code == -2) {
      final host = e.address?.host;
      return NetworkFailure(
        NetworkFailureKind.dnsFailure,
        'Could not resolve host${host == null ? '' : ' "$host"'}. Check the URL and your internet connection.',
        debugDetail: _detail(e),
      );
    }
    if (_refused.contains(code) || message.contains('connection refused')) {
      return NetworkFailure(
        NetworkFailureKind.connectionRefused,
        'Connection refused. Make sure the server is running and the port is correct.',
        debugDetail: _detail(e),
      );
    }
    if (_reset.contains(code) ||
        message.contains('reset by peer') ||
        message.contains('broken pipe')) {
      return NetworkFailure(
        NetworkFailureKind.connectionReset,
        'The connection was reset by the server.',
        debugDetail: _detail(e),
      );
    }
    if (_timedOut.contains(code)) {
      return NetworkFailure(
        NetworkFailureKind.connectionTimeout,
        'Connection timed out while contacting the server.',
        debugDetail: _detail(e),
      );
    }
    if (_unreachable.contains(code)) {
      return NetworkFailure(
        NetworkFailureKind.unknown,
        'Network is unreachable. Check your internet connection.',
        debugDetail: _detail(e),
      );
    }
    return NetworkFailure(
      NetworkFailureKind.unknown,
      'Unable to connect to server.',
      debugDetail: _detail(e),
    );
  }

  static String _formatSeconds(Duration d) {
    final s = d.inMilliseconds / 1000;
    final text = s == s.roundToDouble()
        ? s.toStringAsFixed(0)
        : s.toStringAsFixed(1);
    return '$text second${s == 1 ? '' : 's'}';
  }

  static String _detail(Object error) => Redactor.scrub(error.toString());
}
