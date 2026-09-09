import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:logger/logger.dart';
import 'package:manna/router.dart';
import 'package:manna/services/biometric_services.dart';
import 'package:manna/utils/parser.dart';
import 'package:manna/utils/toast_service.dart';
import 'package:manna/utils/util.dart';
import 'package:manna_core/manna_core.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

Logger? logger;

void logI(dynamic d) => logger?.i(
  d,
  stackTrace: StackTrace.fromString(StackTrace.current.toString().trim().split('\n').sublist(1).join('\n')),
);

void logD(dynamic d) => logger?.d(
  d,
  stackTrace: StackTrace.fromString(StackTrace.current.toString().trim().split('\n').sublist(1).join('\n')),
);

void logE(
  dynamic d, {
  StackTrace? stackTrace,
  dynamic data,
  String? title,
  String? solution,
  bool? showToast,
  bool includeErrorInToast = true,
}) {
  if (d == null) return;
  dynamic e = d;

  if (d is MannaError) {
    e = '${d.kind} - ${d.msg}';
  }
  if (d is LwkError) {
    e = d.msg;
  }
  if (d is BoltzError) {
    e = '${d.kind} - ${d.message}';
  }
  if (d is DioException) {
    e = '${d.message} - ${d.error} - ${d.response?.statusCode} ${d.response?.statusMessage} - ${d.response?.data}';
  }
  final trace =
      stackTrace ?? StackTrace.fromString(StackTrace.current.toString().trim().split('\n').sublist(1).join('\n'));

  logger?.e(data ?? e, error: e, stackTrace: trace);

  if ((showToast ?? true) && ((title?.isNotEmpty ?? false) || (solution?.isNotEmpty ?? false))) {
    final toastMessage = '${title ?? ''}${includeErrorInToast ? '\n$e' : ''}${solution != null ? '\n$solution' : ''}';
    if (e is String && e.contains('swap creation is disabled')) {
      ToastService.show(
        'Boltz swaps to Lightning and L1 are currently disabled. You can receive/send to a Liquid address. We apologize for the inconvenience.',
      );
    } else {
      ToastService.show(toastMessage);
    }
  }

  if (!kDebugMode) {
    FirebaseCrashlytics.instance.recordError(e, trace, information: [?data, ?title, ?solution], printDetails: false);
  }
}

void logTrace() =>
    logger?.t(StackTrace.fromString(StackTrace.current.toString().trim().split('\n').sublist(1).join('\n')));

class CompactPrinter extends LogPrinter {
  CompactPrinter({
    this.maxMessageLength = 5000,
    this.methodCount = 1,
    this.errorMethodCount = 20,
    this.printEmojis = true,
    this.printTime = true,
    this.timeFormatter = _defaultTimeFormatter,
  });

  /// Max length of message or error before truncation (0 = disable)
  final int maxMessageLength;

  /// How many stack frames to show (null = unlimited, 0 = none)
  final int? methodCount;

  /// How many stack frames when error is present
  final int? errorMethodCount;

  /// Whether to print short emoji prefix
  final bool printEmojis;

  /// Whether to print timestamp
  final bool printTime;

  /// Custom date/time formatter (default: simple ISO-like)
  final String Function(DateTime) timeFormatter;

  static String _defaultTimeFormatter(DateTime t) {
    final d = t.toLocal();
    final ms = d.millisecond.toString().padLeft(3, '0');
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:${d.second.toString().padLeft(2, '0')}.$ms';
  }

  static final _levelEmojis = {
    Level.trace: '🔍',
    Level.debug: '🐛',
    Level.info: 'ℹ️',
    Level.warning: '⚡',
    Level.error: '❌',
    Level.fatal: '☢️',
    Level.off: '',
  };

  static final Map<Level, AnsiColor> defaultLevelColors = {
    Level.trace: AnsiColor.fg(AnsiColor.grey(0.5)),
    Level.debug: const AnsiColor.none(),
    Level.info: const AnsiColor.fg(12),
    Level.warning: const AnsiColor.fg(208),
    Level.error: const AnsiColor.fg(196),
    Level.fatal: const AnsiColor.fg(199),
  };

  AnsiColor _getLevelColor(Level level) =>
      !kDebugMode ? const AnsiColor.none() : defaultLevelColors[level] ?? const AnsiColor.none();

  @override
  List<String> log(LogEvent event) {
    final List<String> buffer = [];
    final color = _getLevelColor(event.level);

    final emoji = printEmojis ? (_levelEmojis[event.level] ?? '?') : '';
    final time = printTime ? timeFormatter(event.time) : null;

    final prefix = [?time, '[${event.level.name.toUpperCase()}]', if (emoji.isNotEmpty) emoji].join(' ');

    // Message
    var msg = stringifyMessage(event.message);
    if (maxMessageLength > 0 && msg.length > maxMessageLength) {
      msg = '${msg.substring(0, maxMessageLength)} … [truncated ${msg.length - maxMessageLength} chars]';
    }

    buffer.add(color('$prefix $msg'));

    // Error
    if (event.error != null) {
      var err = event.error.toString();
      if (maxMessageLength > 0 && err.length > maxMessageLength) {
        err = '${err.substring(0, maxMessageLength)} … [truncated]';
      }
      buffer.add(color('  Error: $err'));
    }

    // Stack trace (limited)
    final stack = _formatStackTrace(event.stackTrace, event.error != null ? errorMethodCount : methodCount);

    if (stack != null && stack.isNotEmpty) {
      for (final line in stack.split('\n')) {
        if (line.trim().isNotEmpty) {
          buffer.add(color('    $line'));
        }
      }
    }

    return buffer;
  }

  String? _formatStackTrace(StackTrace? stack, int? maxFrames) {
    if (maxFrames == 0) return null;
    if (stack == null) return null;

    final lines = stack.toString().split('\n');
    final List<String> result = [];

    int count = 0;
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      if (line.contains('package:logger')) continue; // skip logger internals

      result.add(line.trim());
      count++;
      if (maxFrames != null && count >= maxFrames) break;
    }

    return result.isEmpty ? null : result.join('\n');
  }

  String stringifyMessage(dynamic message) {
    final finalMsg = message is Function ? message() : message;

    if (finalMsg == null) return 'null';

    if (finalMsg is Map || finalMsg is Iterable) {
      const encoder = JsonEncoder.withIndent('  ');
      try {
        return encoder.convert(finalMsg);
      } catch (_) {
        return finalMsg.toString();
      }
    }

    return finalMsg.toString();
  }
}

class FileLogOutput extends LogOutput {
  FileLogOutput({
    required String dirPath,
    this._bufferDuration = const Duration(seconds: 2),
    this._maxBufferSize = 2000,
  }) : _file = File(path.join(dirPath, 'flutter.jsonl'));

  final Duration _bufferDuration;
  final int _maxBufferSize;

  final File _file;
  IOSink? _sink;
  Timer? _bufferFlushTimer;

  final List<OutputEvent> _buffer = [];

  @override
  Future<void> init() async {
    _bufferFlushTimer = Timer.periodic(_bufferDuration, (_) => _flushBuffer());
    _sink = _file.openWrite(mode: FileMode.writeOnlyAppend);
  }

  @override
  void output(OutputEvent event) {
    _buffer.add(event);
    if (_buffer.length > _maxBufferSize) {
      _flushBuffer();
    }
  }

  void _flushBuffer() {
    if (_sink == null) return;
    for (final event in _buffer) {
      final line = jsonEncode({
        'ts': event.origin.time.toUtc().toIso8601String(),
        'lvl': event.origin.level.name[0].toUpperCase(),
        'msg': event.origin.message.toString(),
        if (event.origin.error != null) 'err': event.origin.error.toString(),
        if ((event.origin.level == Level.error || event.origin.level == Level.fatal) && event.origin.stackTrace != null)
          'stack': event.origin.stackTrace.toString(),
      });
      _sink?.writeln(line);
    }
    _buffer.clear();
  }

  Future<void> _closeSink() async {
    final sink = _sink;
    _sink = null;

    await sink?.flush();
    await sink?.close();
  }

  @override
  Future<void> destroy() async {
    _bufferFlushTimer?.cancel();
    try {
      _flushBuffer();
    } catch (e) {
      log('Failed to flush buffer before closing the logger: $e');
    }
    await _closeSink();
  }
}

class LogManager {
  static const int keepDays = 14;
  static const int maxFileSizeMB = 15;

  static String? logDirPath;
  static final logTimestampFormat = DateFormat('MMM dd, yyyy hh:mm:ss a');

  static Future<Directory> getLogDirectory() async {
    logDirPath =
        await getAppGroupPath(subPath: 'logs') ?? path.join((await getApplicationSupportDirectory()).path, 'logs');

    if (logDirPath == null) {
      throw 'Failed to access log directory';
    }
    final logDir = Directory(logDirPath!);

    if (!logDir.existsSync()) {
      await logDir.create(recursive: true);
    }
    return logDir;
  }

  static Future<void> cleanupOldLogs() async {
    final logDir = await getLogDirectory();
    final now = DateTime.now();

    try {
      await for (final entity in logDir.list()) {
        if (entity is File) {
          final stat = entity.statSync();
          final ageInDays = now.difference(stat.modified).inDays;

          if (ageInDays > keepDays) {
            await entity.delete();
          }
        }
      }
    } catch (e) {
      debugPrint('Log cleanup error: $e');
    }
  }

  static Future<void> rotateLogIfNeeded(String moduleName) async {
    final logDir = await getLogDirectory();
    final fileName = '$moduleName.jsonl';
    final file = File(path.join(logDir.path, fileName));

    if (!file.existsSync()) return;

    final stat = file.statSync();
    final sizeMB = stat.size / (1024 * 1024);

    if (sizeMB > maxFileSizeMB) {
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      final rotatedName = '${fileName.split('.').first}_$timestamp.jsonl';

      try {
        await file.rename(path.join(logDir.path, rotatedName));
        debugPrint('Rotated log: $rotatedName');
      } catch (_) {}
    }
  }

  static Future<List<File>> getRecentLogFiles({int days = 7}) async {
    final logDir = await getLogDirectory();
    final now = DateTime.now();
    final files = <File>[];

    await for (final entity in logDir.list()) {
      if (entity is File) {
        if (!entity.path.endsWith('.jsonl')) continue;
        final stat = entity.statSync();
        final age = now.difference(stat.modified).inDays;

        if (age <= days) {
          files.add(entity);
        }
      }
    }

    files.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    return files;
  }

  static Future<List<LogEntry>> fetchFileLogs(String filePath) async {
    final List<LogEntry> logs = [];
    final List<String> failed = [];
    const splitter = LineSplitter();

    try {
      final stream = File(filePath).openRead().map(utf8.decode);

      await for (final line in splitter.bind(stream)) {
        try {
          logs.add(LogEntry.fromLine(jsonDecode(line)));
        } catch (e) {
          failed.add(line);
        }
      }

      final lines = splitter.convert(failed.join());
      for (final line in lines) {
        try {
          logs.add(LogEntry.fromLine(jsonDecode(line)));
        } catch (e) {
          if (kDebugMode) {
            print(e);
          }
        }
      }
    } catch (_) {}

    return logs;
  }

  static Future<void> clearAllLogs() async {
    final logDir = await getLogDirectory();
    try {
      await logDir.delete(recursive: true);
      await logDir.create();
      ToastService.show('All logs deleted!');
    } catch (_) {}
  }

  static Future<Uint8List?> exportLogs({bool confirm = true}) async {
    if (!(await BiometricService.authenticateBiometricsIfExists(message: 'Please authenticate to export!'))) {
      return null;
    }
    if (!AppRouter.navigatorContext.mounted) return null;

    if (confirm) {
      final res = await showDialog(
        context: AppRouter.navigatorContext,
        builder: (context) => AlertDialog(
          title: const Text('Notice'),
          content: Text(
            'The log files might contain sensitive information. keep the files safe!',
            style: TextStyle(color: Colors.red.shade300),
          ),
          actions: [TextButton(onPressed: () => AppRouter.pop(true), child: const Text('I know!'))],
        ),
      );
      if (res is! bool || !res) return null;
    }
    try {
      final logDir = await LogManager.getLogDirectory();
      if (logDir.existsSync()) {
        final archive = Archive();

        for (final e in logDir.listSync().whereType<File>()) {
          archive.add(ArchiveFile(path.basename(e.path), await e.length(), await e.readAsBytes()));
        }

        return Uint8List.fromList(ZipEncoder().encode(archive));
      } else {
        ToastService.show('logs not found!');
      }
    } catch (e, s) {
      logE(e, stackTrace: s);
    }

    return null;
  }
}

class LogEntry {
  LogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
    required this.tag,
    required this.error,
    required this.stack,
  });

  factory LogEntry.fromLine(Map<String, dynamic> data) => LogEntry(
    timestamp: parseDateTime(data['ts']).copyWith(isUtc: true),
    level: data['lvl']?.toString() ?? '',
    message: data['msg']?.toString() ?? '',
    tag: data['tag']?.toString(),
    error: data['err']?.toString(),
    stack: data['stack']?.toString(),
  );

  factory LogEntry.fromRustLine(Map<String, dynamic> data) => LogEntry(
    timestamp: parseDateTime(data['timestamp']).copyWith(isUtc: true),
    level: data['level']?.toString() ?? '',
    message: data['fields']?['message']?.toString() ?? '',
    tag: data['target']?.toString(),
    error: data['fields']?['error']?.toString(),
    stack: '${data['filename']}:${data['line_number']}${data['spans'] != null ? '\nspans:${data['spans']}' : ''}',
  );

  final DateTime timestamp;
  final String level;
  final String message;
  final String? tag;
  final String? error;
  final String? stack;

  Map<String, dynamic> toMap() => {
    'timestamp': LogManager.logTimestampFormat.format(timestamp),
    'level':
        (level.length == 1
                ? switch (level.toLowerCase()) {
                    'v' => 'verbose',
                    'd' => 'debug',
                    'i' => 'info',
                    't' => 'trace',
                    'w' => 'warning',
                    'e' => 'error',
                    'f' => 'fatal',
                    _ => '',
                  }
                : level)
            .toUpperCase(),
    'message': message,
    'tag': tag,
    'error': error,
    'stack': stack,
  };
}
