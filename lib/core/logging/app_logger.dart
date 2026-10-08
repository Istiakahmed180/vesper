import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../security/redactor.dart';

enum LogLevel { debug, info, warning, error }

class LogRecord {
  const LogRecord({
    required this.level,
    required this.message,
    required this.time,
    this.context = const {},
    this.error,
  });

  final LogLevel level;
  final String message;
  final DateTime time;
  final Map<String, Object?> context;
  final Object? error;

  String format() {
    final buffer = StringBuffer()
      ..write(time.toIso8601String())
      ..write(' [')
      ..write(level.name.toUpperCase())
      ..write('] ')
      ..write(message);
    if (context.isNotEmpty) {
      buffer.write(' ');
      buffer.write(
        context.entries
            .map((e) => '${e.key}=${_value(e.key, e.value)}')
            .join(' '),
      );
    }
    if (error != null) {
      buffer
        ..write(' error=')
        ..write(error.runtimeType);
    }
    return Redactor.scrub(buffer.toString());
  }

  static String _value(String key, Object? value) {
    if (Redactor.isSensitiveKey(key)) return Redactor.mask;
    return '$value';
  }
}

abstract class LogSink {
  void write(LogRecord record);
  Future<void> close() async {}
}

class ConsoleLogSink implements LogSink {
  @override
  void write(LogRecord record) => debugPrint(record.format());

  @override
  Future<void> close() async {}
}

/// Appends to `vesper.log`, rotating once the file exceeds [maxBytes].
class FileLogSink implements LogSink {
  FileLogSink(this.directory, {this.maxBytes = 2 * 1024 * 1024});

  final Directory directory;
  final int maxBytes;
  // Closed in [close].
  // ignore: close_sinks
  IOSink? _sink;
  File? _file;
  int _written = 0;

  File get file => _file ??= File(p.join(directory.path, 'vesper.log'));

  void _open() {
    if (_sink != null) return;
    directory.createSync(recursive: true);
    if (file.existsSync() && file.lengthSync() > maxBytes) {
      final rotated = File(p.join(directory.path, 'vesper.1.log'));
      if (rotated.existsSync()) rotated.deleteSync();
      file.renameSync(rotated.path);
      _file = null;
    }
    _written = file.existsSync() ? file.lengthSync() : 0;
    _sink = file.openWrite(mode: FileMode.append);
  }

  @override
  void write(LogRecord record) {
    try {
      _open();
      final line = '${record.format()}\n';
      _sink!.write(line);
      _written += line.length;
      if (_written > maxBytes) {
        unawaited(close());
      }
    } catch (_) {
      // Logging must never take the application down.
    }
  }

  @override
  Future<void> close() async {
    final sink = _sink;
    _sink = null;
    await sink?.flush();
    await sink?.close();
  }
}

/// Structured logger. Callers pass context as key/values; values whose key
/// looks sensitive are masked and free text is scrubbed of token patterns.
class AppLogger {
  AppLogger({List<LogSink>? sinks, this.minLevel = LogLevel.info})
    : _sinks = sinks ?? [ConsoleLogSink()];

  final List<LogSink> _sinks;
  LogLevel minLevel;

  void addSink(LogSink sink) => _sinks.add(sink);

  void debug(String message, [Map<String, Object?> context = const {}]) =>
      _log(LogLevel.debug, message, context);

  void info(String message, [Map<String, Object?> context = const {}]) =>
      _log(LogLevel.info, message, context);

  void warning(String message, [Map<String, Object?> context = const {}]) =>
      _log(LogLevel.warning, message, context);

  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> context = const {},
  }) {
    _log(LogLevel.error, message, {
      ...context,
      if (error != null) 'detail': Redactor.scrub(error.toString()),
    }, error);
    if (stackTrace != null && kDebugMode) {
      debugPrint(stackTrace.toString());
    }
  }

  void _log(
    LogLevel level,
    String message,
    Map<String, Object?> context, [
    Object? error,
  ]) {
    if (level.index < minLevel.index) return;
    final record = LogRecord(
      level: level,
      message: message,
      time: DateTime.now(),
      context: context,
      error: error,
    );
    for (final sink in _sinks) {
      sink.write(record);
    }
  }

  Future<void> close() async {
    for (final sink in _sinks) {
      await sink.close();
    }
  }
}
