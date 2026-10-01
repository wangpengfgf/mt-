import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import 'api_service.dart';

/// 黑名单条目：个人（本机手动拉黑）或服务端（Discuz 黑名单同步）。
class BlacklistEntry {
  final String uid;
  final String username;
  final int time;
  final String source; // local / server

  const BlacklistEntry({
    required this.uid,
    required this.username,
    required this.source,
    this.time = 0,
  });

  String get displayName => username.isNotEmpty ? username : 'UID $uid';

  Map<String, dynamic> toJson() => {
        'uid': uid,
        'user': username,
        'time': time,
      };

  static BlacklistEntry? fromJson(
    Map<String, dynamic> o, {
    required String source,
  }) {
    final uid = '${o['uid'] ?? ''}';
    if (uid.isEmpty) return null;
    return BlacklistEntry(
      uid: uid,
      username: '${o['user'] ?? ''}',
      time: (o['time'] as num?)?.toInt() ?? 0,
      source: source,
    );
  }
}

/// 个人小黑屋：合并「个人黑名单」与「服务端黑名单」，并提供 uid 过滤。
///
/// 过滤只发生在客户端展示层，不会向论坛提交屏蔽规则。
class BlacklistService extends ChangeNotifier {
  BlacklistService._();

  static final BlacklistService instance = BlacklistService._();

  static const _localKey = 'sqapp_blacklist_local';
  static const _serverKey = 'sqapp_blacklist_server';
  static const _serverTsKey = 'sqapp_blacklist_server_ts';
  static const _syncInterval = Duration(days: 7);

  List<BlacklistEntry> _local = const [];
  List<BlacklistEntry> _server = const [];
  Set<String> _uidSet = const {};
  bool _loaded = false;

  List<BlacklistEntry> get local => List.unmodifiable(_local);
  List<BlacklistEntry> get server => List.unmodifiable(_server);
  List<BlacklistEntry> get all => [..._local, ..._server];
  int get size => _local.length + _server.length;
  bool get isEmpty => _local.isEmpty && _server.isEmpty;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _local = _parse(prefs.getString(_localKey), 'local');
    _server = _parse(prefs.getString(_serverKey), 'server');
    _rebuildUidSet();
    _loaded = true;
    notifyListeners();
  }

  bool isBlack(String? uid) {
    if (uid == null || uid.isEmpty) return false;
    if (!_loaded) return false;
    return _uidSet.contains(uid);
  }

  // ═══ 个人黑名单 ═══

  Future<void> addLocal(String uid, String username) async {
    if (uid.isEmpty) return;
    if (_local.any((e) => e.uid == uid)) return;
    _local = [
      ..._local,
      BlacklistEntry(
        uid: uid,
        username: username,
        source: 'local',
        time: DateTime.now().millisecondsSinceEpoch,
      ),
    ];
    _rebuildUidSet();
    notifyListeners();
    await _persistLocal();
  }

  Future<void> removeLocal(String uid) async {
    final next = _local.where((e) => e.uid != uid).toList();
    if (next.length == _local.length) return;
    _local = next;
    _rebuildUidSet();
    notifyListeners();
    await _persistLocal();
  }

  Future<void> clearLocal() async {
    if (_local.isEmpty) return;
    _local = const [];
    _rebuildUidSet();
    notifyListeners();
    await _persistLocal();
  }

  // ═══ 服务端黑名单 ═══

  Future<void> removeServer(String uid) async {
    final next = _server.where((e) => e.uid != uid).toList();
    if (next.length == _server.length) return;
    _server = next;
    _rebuildUidSet();
    notifyListeners();
    await _persistServer();
  }

  Future<bool> needsServerSync() async {
    final prefs = await SharedPreferences.getInstance();
    final ts = prefs.getInt(_serverTsKey) ?? 0;
    if (ts == 0) return true;
    return DateTime.now().millisecondsSinceEpoch - ts >
        _syncInterval.inMilliseconds;
  }

  /// 需要时拉取服务端黑名单；返回错误信息（成功为 null）。
  Future<String?> syncIfNeeded() async {
    if (!await needsServerSync()) return null;
    return sync();
  }

  /// 强制拉取服务端黑名单；返回错误信息（成功为 null）。
  Future<String?> sync() async {
    if (!ApiService.instance.isLoggedIn) return null;
    try {
      final users = await ApiService.instance.getSocialUsers(
        type: 'blacklist',
        uid: ApiService.instance.currentUid ?? '',
      );
      _server = [
        for (final u in users)
          if (u.uid.isNotEmpty)
            BlacklistEntry(
              uid: u.uid,
              username: u.username,
              source: 'server',
            ),
      ];
      _rebuildUidSet();
      notifyListeners();
      await _persistServer();
      return null;
    } catch (e) {
      return '同步失败：$e';
    }
  }

  // ═══ 过滤 ═══

  List<Thread> filterThreads(List<Thread> list) {
    if (_uidSet.isEmpty) return list;
    return list.where((t) => !isBlack(t.authorUid)).toList(growable: false);
  }

  /// 过滤帖子楼层：始终保留楼主楼层，避免详情页整页变空。
  List<Post> filterPosts(List<Post> list) {
    if (_uidSet.isEmpty) return list;
    return list
        .where((p) => p.isOp || !isBlack(p.authorUid))
        .toList(growable: false);
  }

  // ═══ 内部 ═══

  void _rebuildUidSet() {
    _uidSet = {
      for (final e in _local)
        if (e.uid.isNotEmpty) e.uid,
      for (final e in _server)
        if (e.uid.isNotEmpty) e.uid,
    };
  }

  List<BlacklistEntry> _parse(String? raw, String source) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final arr = jsonDecode(raw);
      if (arr is! List) return const [];
      final out = <BlacklistEntry>[];
      for (final item in arr) {
        if (item is Map) {
          final e = BlacklistEntry.fromJson(
            Map<String, dynamic>.from(item),
            source: source,
          );
          if (e != null) out.add(e);
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _persistLocal() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _localKey,
      jsonEncode([for (final e in _local) e.toJson()]),
    );
  }

  Future<void> _persistServer() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _serverKey,
      jsonEncode([
        for (final e in _server) {'uid': e.uid, 'user': e.username},
      ]),
    );
    await prefs.setInt(
      _serverTsKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  }
}
