import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 运行日志。
///
/// 自动回复 / 签到 / AI 调用的结果都往这里塞一份，设置页「运行日志」里查看。
/// 同时把日志追加写到应用文档目录，App 被杀后仍可回看，便于排查静默失败。
class AiLog {
  AiLog._();

  static const int maxEntries = 300;
  static const int maxFileBytes = 512 * 1024;

  static final List<String> _entries = [];
  static File? _file;
  static bool _attached = false;

  /// 指定日志落盘位置（一般在应用启动时调用一次）。
  static Future<void> attach() async {
    if (_attached) return;
    _attached = true;
    try {
      final dir = await getApplicationDocumentsDirectory();
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _file = File('${dir.path}/ai_run.log');
    } catch (_) {
      // 拿不到目录也不影响内存日志
    }
  }

  static String get filePath => _file?.path ?? '';

  static void i(String tag, String msg) => _add(tag, msg);

  static void e(String tag, String msg) => _add(tag, msg);

  static void _add(String tag, String msg) {
    final line =
        '${_formatTime(DateTime.now())} [${tag.isEmpty ? '-' : tag}] $msg';
    _entries.add(line);
    while (_entries.length > maxEntries) {
      _entries.removeAt(0);
    }
    unawaited(_appendLine(line));
  }

  static Future<void> _appendLine(String line) async {
    final f = _file;
    if (f == null) return;
    try {
      if (await f.exists() && await f.length() > maxFileBytes) {
        await f.delete();
      }
      await f.writeAsString('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // 落盘失败不影响主流程
    }
  }

  /// 返回倒序拼接的完整日志文本（最新在最上面）
  static String dump() {
    if (_entries.isEmpty) return '暂无日志';
    final sb = StringBuffer();
    for (var i = _entries.length - 1; i >= 0; i--) {
      sb.writeln(_entries[i]);
    }
    return sb.toString();
  }

  static int get size => _entries.length;

  static bool get isEmpty => _entries.isEmpty;

  static void clear() => _entries.clear();

  /// 便捷：截断长文本
  static String clip(String? s, int max) {
    if (s == null || s.isEmpty) return '';
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length > max ? '${t.substring(0, max)}…' : t;
  }

  static String _formatTime(DateTime t) {
    String two(int v) => v < 10 ? '0$v' : '$v';
    return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:'
        '${two(t.minute)}:${two(t.second)}';
  }
}
