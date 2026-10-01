import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 崩溃 / 错误日志收集器（对齐 Java 版 CrashHandler）。
///
/// 1. 全局未捕获异常自动写入 crash_*.log；
/// 2. 任意位置可通过 [logError] 记录错误，写入 error_*.log；
/// 3. 日志存放于应用私有目录，可在设置页查看 / 复制 / 清空。
class ErrorLogService {
  ErrorLogService._();

  static final ErrorLogService instance = ErrorLogService._();

  Directory? _dir;
  bool _initialized = false;

  /// 日志目录路径（未初始化时为空串）。
  String get logDirPath => _dir?.path ?? '';

  /// 注册全局异常钩子并准备日志目录，应在 runApp 之前调用。
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    try {
      final base = await getApplicationDocumentsDirectory();
      final dir = Directory('${base.path}/crash');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _dir = dir;
    } catch (_) {
      _dir = null;
    }

    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      unawaited(
        logCrash(details.exception, details.stack, source: 'FlutterError'),
      );
      previous?.call(details);
    };

    ui.PlatformDispatcher.instance.onError = (error, stack) {
      unawaited(logCrash(error, stack, source: 'Uncaught'));
      return false;
    };
  }

  /// 记录一次崩溃日志（crash_yyyyMMdd_HHmmss.log）。
  Future<void> logCrash(
    Object? error,
    StackTrace? stack, {
    String source = 'unknown',
  }) {
    final sb = StringBuffer()
      ..writeln('=== 崩溃日志 ===')
      ..writeln('时间: ${_timestamp()}')
      ..writeln('来源: $source')
      ..writeln()
      ..writeln('--- 异常信息 ---')
      ..writeln(error?.toString() ?? '(无)');
    if (stack != null) sb.writeln(stack.toString());
    _appendDeviceInfo(sb);
    return _write('crash', sb.toString());
  }

  /// 记录一次普通错误日志（error_yyyyMMdd_HHmmss.log）。
  Future<void> logError(String tag, Object? error, [StackTrace? stack]) {
    final sb = StringBuffer()
      ..writeln('=== 错误日志 ===')
      ..writeln('时间: ${_timestamp()}')
      ..writeln('来源: $tag')
      ..writeln()
      ..writeln('--- 异常信息 ---')
      ..writeln(error?.toString() ?? '(无)');
    if (stack != null) sb.writeln(stack.toString());
    _appendDeviceInfo(sb);
    return _write('error', sb.toString());
  }

  void _appendDeviceInfo(StringBuffer sb) {
    sb
      ..writeln()
      ..writeln('--- 设备信息 ---')
      ..writeln('系统: ${Platform.operatingSystem}')
      ..writeln('版本: ${Platform.operatingSystemVersion}');
  }

  Future<void> _write(String type, String content) async {
    final dir = _dir;
    if (dir == null) return;
    try {
      if (!await dir.exists()) await dir.create(recursive: true);
      final file = File('${dir.path}/${type}_${_fileStamp()}.log');
      await file.writeAsString(content);
    } catch (_) {
      // 日志写入失败不应影响主流程。
    }
  }

  /// 全部日志文件，按修改时间倒序。
  Future<List<File>> listLogs() async {
    final dir = _dir;
    if (dir == null || !await dir.exists()) return const [];
    try {
      final files = await dir
          .list()
          .where((e) => e is File && e.path.endsWith('.log'))
          .cast<File>()
          .toList();
      files.sort(
        (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
      );
      return files;
    } catch (_) {
      return const [];
    }
  }

  Future<String> readLog(File file) async {
    try {
      return await file.readAsString();
    } catch (e) {
      return '读取失败: $e';
    }
  }

  Future<void> deleteLog(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<void> clearAll() async {
    final files = await listLogs();
    for (final file in files) {
      await deleteLog(file);
    }
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  String _timestamp() {
    final n = DateTime.now();
    return '${n.year}-${_two(n.month)}-${_two(n.day)} '
        '${_two(n.hour)}:${_two(n.minute)}:${_two(n.second)}';
  }

  String _fileStamp() {
    final n = DateTime.now();
    return '${n.year}${_two(n.month)}${_two(n.day)}_'
        '${_two(n.hour)}${_two(n.minute)}${_two(n.second)}';
  }
}
