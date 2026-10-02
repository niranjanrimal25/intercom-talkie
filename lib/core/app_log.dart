import 'dart:collection';

import 'package:flutter/foundation.dart';

/// Severity levels used by the in-app log.
enum LogLevel { debug, info, warn, error }

/// A single log record.
class LogEntry {
  LogEntry(this.time, this.level, this.tag, this.message);

  final DateTime time;
  final LogLevel level;
  final String tag;
  final String message;

  String get levelName => level.name;

  String format() {
    final hh = time.hour.toString().padLeft(2, '0');
    final mm = time.minute.toString().padLeft(2, '0');
    final ss = time.second.toString().padLeft(2, '0');
    final ms = time.millisecond.toString().padLeft(3, '0');
    return '$hh:$mm:$ss.$ms ${level.name.toUpperCase().padLeft(5)} [$tag] $message';
  }
}

/// Application-wide ring-buffer logger.
///
/// Kept deliberately dependency-free: a bounded list plus a [ValueNotifier]
/// tick the UI can listen to.
class AppLog {
  AppLog._() {
    _entries = Queue<LogEntry>();
  }

  static final AppLog instance = AppLog._();

  static const int _capacity = 800;

  late final Queue<LogEntry> _entries;

  /// Bumped on every appended entry so widgets can rebuild cheaply.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  int _dropCount = 0;

  void log(LogLevel level, String tag, String message) {
    if (_entries.length >= _capacity) {
      _entries.removeFirst();
      _dropCount++;
    }
    _entries.add(LogEntry(DateTime.now(), level, tag, message));
    revision.value++;
    if (kDebugMode) {
      debugPrint(LogEntry(DateTime.now(), level, tag, message).format());
    }
  }

  void d(String tag, String message) => log(LogLevel.debug, tag, message);
  void i(String tag, String message) => log(LogLevel.info, tag, message);
  void w(String tag, String message) => log(LogLevel.warn, tag, message);
  void e(String tag, String message) => log(LogLevel.error, tag, message);

  /// Newest-last snapshot of the current entries.
  List<LogEntry> snapshot() => _entries.toList(growable: false);

  int get droppedCount => _dropCount;

  /// Renders the whole buffer to a plain-text blob (for sharing).
  String export() {
    final buffer = StringBuffer();
    if (_dropCount > 0) {
      buffer.writeln('... $_dropCount older entries dropped ...');
    }
    for (final entry in _entries) {
      buffer.writeln(entry.format());
    }
    return buffer.toString();
  }

  void clear() {
    _entries.clear();
    _dropCount = 0;
    revision.value++;
  }
}
