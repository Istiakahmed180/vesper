import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/core/errors/app_failure.dart';
import 'package:vesper/core/network/network_error_mapper.dart';

void main() {
  const mapper = NetworkErrorMapper();
  NetworkFailureKind kindOf(String message, int code) => mapper
      .map(
        SocketException('Connection failed', osError: OSError(message, code)),
        timeout: const Duration(seconds: 30),
      )
      .kind;

  test('connection refused on every platform', () {
    expect(
      kindOf('Connection refused', 61),
      NetworkFailureKind.connectionRefused,
    ); // macOS
    expect(
      kindOf('Connection refused', 111),
      NetworkFailureKind.connectionRefused,
    ); // Linux
    expect(
      kindOf(
        'No connection could be made because the target machine actively refused it.',
        10061,
      ),
      NetworkFailureKind.connectionRefused,
    );
    expect(
      kindOf('The remote computer refused the network connection.', 1225),
      NetworkFailureKind.connectionRefused,
    ); // Windows, as reported by Dart
  });

  test('DNS, reset and timeouts on Windows', () {
    expect(
      kindOf('No such host is known.', 11001),
      NetworkFailureKind.dnsFailure,
    );
    expect(
      kindOf('The network connection was aborted by the local system.', 1236),
      NetworkFailureKind.connectionReset,
    );
    expect(
      kindOf('The semaphore timeout period has expired.', 121),
      NetworkFailureKind.connectionTimeout,
    );
  });
}
