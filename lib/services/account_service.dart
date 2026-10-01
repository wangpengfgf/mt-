import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'api_service.dart';

/// 已保存的账号快照。
class SavedAccount {
  final String uid;
  final String username;
  final String avatar;
  final String level;
  final String auth;
  final String saltkey;

  const SavedAccount({
    required this.uid,
    required this.username,
    required this.avatar,
    required this.level,
    required this.auth,
    required this.saltkey,
  });

  String get displayName => username.isEmpty ? 'UID_$uid' : username;

  Map<String, dynamic> toJson() => {
        'uid': uid,
        'username': username,
        'avatar': avatar,
        'level': level,
        'auth': auth,
        'saltkey': saltkey,
      };

  static SavedAccount? fromJson(Map<String, dynamic> o) {
    final uid = '${o['uid'] ?? ''}';
    final auth = '${o['auth'] ?? ''}';
    final saltkey = '${o['saltkey'] ?? ''}';
    if (uid.isEmpty || auth.isEmpty || saltkey.isEmpty) return null;
    return SavedAccount(
      uid: uid,
      username: '${o['username'] ?? ''}',
      avatar: '${o['avatar'] ?? ''}',
      level: '${o['level'] ?? ''}',
      auth: auth,
      saltkey: saltkey,
    );
  }
}

/// 多账号管理器：保存多份登录会话快照，一键切换。
///
/// 切换 = 用快照的 auth/saltkey 整体替换 ApiService 的当前登录态。
class AccountService {
  AccountService._();

  static const String _listKey = 'sqapp_accounts';
  static const String _activeKey = 'active_uid';

  static Future<SharedPreferences> _prefs() async {
    return SharedPreferences.getInstance();
  }

  static List<SavedAccount> _parse(String? json) {
    if (json == null || json.isEmpty) return [];
    try {
      final arr = jsonDecode(json);
      if (arr is! List) return [];
      final out = <SavedAccount>[];
      for (final item in arr) {
        if (item is Map) {
          final a = SavedAccount.fromJson(Map<String, dynamic>.from(item));
          if (a != null) out.add(a);
        }
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  static String _encode(List<SavedAccount> list) {
    return jsonEncode([for (final a in list) a.toJson()]);
  }

  /// 账号列表。
  static Future<List<SavedAccount>> list() async {
    final p = await _prefs();
    return _parse(p.getString(_listKey));
  }

  /// 当前激活账号 uid。
  static Future<String?> activeUid() async {
    final p = await _prefs();
    return p.getString(_activeKey);
  }

  /// 把当前登录态保存为新账号（uid 相同则覆盖更新）。
  static Future<bool> saveCurrent() async {
    final api = ApiService.instance;
    if (!api.isLoggedIn) return false;
    final auth = api.auth;
    final saltkey = api.saltkey;
    if (auth == null || saltkey == null) return false;

    var uid = api.currentUid ?? '';
    var username = '';
    var avatar = '';
    var level = '';
    try {
      final profile = await api.getProfile();
      if (profile.uid.isNotEmpty && profile.uid != '0') uid = profile.uid;
      username = profile.username ?? '';
      avatar = profile.avatarUrl ?? '';
      level = profile.userGroup ?? '';
    } catch (_) {
      // 读取资料失败时保留已有 uid，用户名为空时用 UID 兜底。
    }
    if (uid.isEmpty) return false;

    final p = await _prefs();
    final accounts = _parse(p.getString(_listKey));
    final account = SavedAccount(
      uid: uid,
      username: username,
      avatar: avatar,
      level: level,
      auth: auth,
      saltkey: saltkey,
    );

    final out = <SavedAccount>[];
    var replaced = false;
    for (final a in accounts) {
      if (a.uid == uid) {
        out.add(account);
        replaced = true;
      } else {
        out.add(a);
      }
    }
    if (!replaced) out.add(account);

    await p.setString(_listKey, _encode(out));
    await p.setString(_activeKey, uid);
    return true;
  }

  /// 切换账号。
  static Future<bool> switchTo(String uid) async {
    final accounts = await list();
    SavedAccount? target;
    for (final a in accounts) {
      if (a.uid == uid) {
        target = a;
        break;
      }
    }
    if (target == null) return false;

    await ApiService.instance.applySession(
      auth: target.auth,
      saltkey: target.saltkey,
      uid: target.uid,
    );

    final p = await _prefs();
    await p.setString(_activeKey, uid);
    return true;
  }

  /// 删除账号。
  static Future<void> remove(String uid) async {
    final p = await _prefs();
    final accounts = _parse(p.getString(_listKey));
    accounts.removeWhere((a) => a.uid == uid);
    await p.setString(_listKey, _encode(accounts));
    if (p.getString(_activeKey) == uid) {
      await p.remove(_activeKey);
    }
  }
}
