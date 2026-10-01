import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 发帖草稿。
class DraftEntry {
  final int id;
  final String title;
  final String content;
  final String fid;
  final String forumName;
  final bool anonymous;
  final int time;

  const DraftEntry({
    required this.id,
    required this.title,
    required this.content,
    required this.fid,
    required this.forumName,
    required this.anonymous,
    required this.time,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'content': content,
        'fid': fid,
        'forum': forumName,
        'anon': anonymous,
        'time': time,
      };

  static DraftEntry? fromJson(Map<String, dynamic> o) {
    final id = (o['id'] as num?)?.toInt() ?? 0;
    if (id <= 0) return null;
    return DraftEntry(
      id: id,
      title: '${o['title'] ?? ''}',
      content: '${o['content'] ?? ''}',
      fid: '${o['fid'] ?? ''}',
      forumName: '${o['forum'] ?? ''}',
      anonymous: o['anon'] == true,
      time: (o['time'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 发帖草稿箱：本地持久化，最多 [maxDrafts] 条，按时间倒序。
///
/// 编辑页退出时自动保存，发布成功后自动删除对应草稿。
class DraftService {
  DraftService._();

  static const String _listKey = 'sqapp_drafts';
  static const int maxDrafts = 20;

  static Future<SharedPreferences> _prefs() async {
    return SharedPreferences.getInstance();
  }

  static List<DraftEntry> _parse(String? json) {
    if (json == null || json.isEmpty) return [];
    try {
      final arr = jsonDecode(json);
      if (arr is! List) return [];
      final out = <DraftEntry>[];
      for (final item in arr) {
        if (item is Map) {
          final e = DraftEntry.fromJson(Map<String, dynamic>.from(item));
          if (e != null) out.add(e);
        }
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  static String _encode(List<DraftEntry> list) {
    return jsonEncode([for (final e in list) e.toJson()]);
  }

  /// 全部草稿，最新在前。
  static Future<List<DraftEntry>> list() async {
    final p = await _prefs();
    final out = _parse(p.getString(_listKey));
    out.sort((a, b) => b.time.compareTo(a.time));
    return out;
  }

  /// 最新一条草稿，无草稿返回 null。
  static Future<DraftEntry?> latest() async {
    final l = await list();
    return l.isEmpty ? null : l.first;
  }

  /// 保存或更新草稿（id > 0 且存在则覆盖并刷新时间），返回草稿 id。
  static Future<int> save({
    int id = 0,
    required String title,
    required String content,
    String fid = '',
    String forumName = '',
    bool anonymous = false,
  }) async {
    final p = await _prefs();
    final l = _parse(p.getString(_listKey));
    var newId = id;
    if (id > 0) {
      final exists = l.any((x) => x.id == id);
      if (!exists) newId = 0;
      l.removeWhere((x) => x.id == id);
    }
    if (newId <= 0) newId = DateTime.now().millisecondsSinceEpoch;
    l.add(DraftEntry(
      id: newId,
      title: title,
      content: content,
      fid: fid,
      forumName: forumName,
      anonymous: anonymous,
      time: DateTime.now().millisecondsSinceEpoch,
    ));
    // 超上限丢最旧。
    while (l.length > maxDrafts) {
      var oldest = l.first;
      for (final x in l) {
        if (x.time < oldest.time) oldest = x;
      }
      l.remove(oldest);
    }
    await p.setString(_listKey, _encode(l));
    return newId;
  }

  static Future<void> delete(int id) async {
    if (id <= 0) return;
    final p = await _prefs();
    final l = _parse(p.getString(_listKey));
    l.removeWhere((x) => x.id == id);
    await p.setString(_listKey, _encode(l));
  }

  static Future<void> clear() async {
    final p = await _prefs();
    await p.setString(_listKey, '[]');
  }
}
