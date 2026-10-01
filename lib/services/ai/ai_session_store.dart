import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

import 'ai_client.dart';

/// 会话条目（索引行）
class AiSession {
  String id;
  String title;
  int createdAt;
  int updatedAt;
  int messageCount;

  AiSession({
    required this.id,
    this.title = '新会话',
    this.createdAt = 0,
    this.updatedAt = 0,
    this.messageCount = 0,
  });
}

/// AI 会话存储（Codex 风格）。
///
/// 每个会话一个 JSON 文件，目录结构：
///   <documents>/ai_sessions/
///     ├── index.json           —— 会话索引
///     └── <id>.json            —— 完整消息列表（含 tool 往返）
///
/// 写入策略：每轮对话结束后立即落盘。
class AiSessionStore {
  AiSessionStore._();

  static Directory? _dir;

  static Future<Directory> sessionsDir() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/ai_sessions');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _dir = dir;
    return dir;
  }

  static Future<File> _indexFile() async =>
      File('${(await sessionsDir()).path}/index.json');

  // ==================== 索引 ====================

  /// 读取全部会话，按最后活跃时间倒序（最新的在前）
  static Future<List<AiSession>> listSessions() async {
    final out = <AiSession>[];
    try {
      final f = await _indexFile();
      if (!await f.exists()) return out;
      final root = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final arr = root['sessions'];
      if (arr is! List) return out;
      for (final item in arr) {
        if (item is! Map) continue;
        final id = '${item['id'] ?? ''}';
        if (id.isEmpty) continue;
        out.add(
          AiSession(
            id: id,
            title: '${item['title'] ?? '新会话'}',
            createdAt: (item['createdAt'] as num?)?.toInt() ?? 0,
            updatedAt: (item['updatedAt'] as num?)?.toInt() ?? 0,
            messageCount: (item['messageCount'] as num?)?.toInt() ?? 0,
          ),
        );
      }
    } catch (_) {}
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  /// 新建会话，返回会话 id（索引立即写入）
  static Future<String> createSession() async {
    final id = _randomId();
    final s = AiSession(
      id: id,
      title: '新会话',
      createdAt: DateTime.now().millisecondsSinceEpoch,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    final all = await listSessions();
    all.insert(0, s);
    await _writeIndex(all);
    return id;
  }

  /// 删除会话（索引 + 会话文件）
  static Future<void> deleteSession(String id) async {
    if (id.isEmpty) return;
    try {
      final f = File('${(await sessionsDir()).path}/$id.json');
      if (await f.exists()) await f.delete();
    } catch (_) {}
    final all = await listSessions();
    all.removeWhere((s) => s.id == id);
    await _writeIndex(all);
  }

  /// 重命名会话
  static Future<void> renameSession(String id, String newTitle) async {
    if (newTitle.isEmpty) return;
    final all = await listSessions();
    for (final s in all) {
      if (s.id == id) {
        s.title = newTitle;
        break;
      }
    }
    await _writeIndex(all);
  }

  // ==================== 消息存取 ====================

  /// 加载会话完整消息列表（含 tool 往返）；文件不存在或损坏返回空列表
  static Future<List<AiMsg>> loadMessages(String id) async {
    final out = <AiMsg>[];
    if (id.isEmpty) return out;
    try {
      final f = File('${(await sessionsDir()).path}/$id.json');
      if (!await f.exists()) return out;
      final root = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final arr = root['messages'];
      if (arr is! List) return out;
      for (final item in arr) {
        if (item is Map<String, dynamic>) out.add(AiMsg.fromJson(item));
      }
    } catch (_) {}
    return out;
  }

  /// 全量落盘整个会话（history 全量写，工具往返原样保留）
  static Future<void> saveMessages(
    String id,
    List<AiMsg> msgs,
    String? title,
  ) async {
    if (id.isEmpty) return;
    try {
      final dir = await sessionsDir();
      final root = <String, dynamic>{
        'id': id,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
        'messages': [
          for (final m in msgs)
            if (!m.internal) m.toJson(),
        ],
      };
      await File('${dir.path}/$id.json').writeAsString(jsonEncode(root));

      // 同步索引：时间、消息数；标题只在非空时替换
      final all = await listSessions();
      var found = false;
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final s in all) {
        if (s.id == id) {
          s.updatedAt = now;
          s.messageCount = msgs.length;
          if (title != null && title.isNotEmpty) s.title = title;
          found = true;
          break;
        }
      }
      if (!found) {
        all.insert(
          0,
          AiSession(
            id: id,
            title: (title == null || title.isEmpty) ? '新会话' : title,
            createdAt: now,
            updatedAt: now,
            messageCount: msgs.length,
          ),
        );
      }
      await _writeIndex(all);
    } catch (_) {}
  }

  /// 从消息列表里取会话标题：首条 user 消息前 30 字
  static String? titleFromMessages(List<AiMsg> msgs) {
    for (final m in msgs) {
      if (m.role == 'user' && m.content.isNotEmpty) {
        final t = m.content.trim();
        return t.length <= 30 ? t : t.substring(0, 30);
      }
    }
    return null;
  }

  // ==================== 文件 IO ====================

  static Future<void> _writeIndex(List<AiSession> sessions) async {
    try {
      final f = await _indexFile();
      final root = <String, dynamic>{
        'version': 1,
        'sessions': [
          for (final s in sessions)
            {
              'id': s.id,
              'title': s.title,
              'createdAt': s.createdAt,
              'updatedAt': s.updatedAt,
              'messageCount': s.messageCount,
            },
        ],
      };
      await f.writeAsString(jsonEncode(root));
    } catch (_) {}
  }

  static String _randomId() {
    const chars = '0123456789abcdef';
    final rnd = Random();
    final sb = StringBuffer();
    for (var i = 0; i < 12; i++) {
      sb.write(chars[rnd.nextInt(chars.length)]);
    }
    return sb.toString();
  }
}
