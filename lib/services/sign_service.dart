import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import 'account_service.dart';
import 'api_service.dart';

/// 单个账号的自动签到结果。
class AutoSignAccountResult {
  final String name;

  /// 本次是否真正发起了签到请求；false 表示今日已签到或已跳过。
  final bool attempted;
  final bool success;
  final String message;

  const AutoSignAccountResult({
    required this.name,
    required this.attempted,
    required this.success,
    required this.message,
  });
}

class AutoSignOutcome {
  final bool attempted;
  final bool success;
  final String message;
  final List<AutoSignAccountResult> accounts;

  const AutoSignOutcome({
    required this.attempted,
    required this.success,
    required this.message,
    this.accounts = const [],
  });

  const AutoSignOutcome.skipped([this.message = ''])
      : attempted = false,
        success = true,
        accounts = const [];
}

class SignService {
  SignService._();

  static final SignService instance = SignService._();

  static const String _autoSignKey = 'auto_sign_enabled';
  static const String _lastSignDateKey = 'auto_sign_last_success_date';
  static const String _lastSignAuthsKey = 'auto_sign_last_success_auths';

  final ApiService _api = ApiService.instance;

  Future<bool> getAutoSignEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoSignKey) ?? false;
  }

  Future<void> setAutoSignEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoSignKey, enabled);
  }

  /// 当前登录账号今天是否已经签到。
  Future<bool> hasSignedToday() async {
    final auth = _api.auth;
    if (auth == null || auth.isEmpty) {
      return false;
    }

    return (await _signedAuthsToday()).contains(auth);
  }

  Future<bool> syncTodayStatus() async {
    if (await hasSignedToday()) {
      return true;
    }

    if (!_api.isLoggedIn) {
      return false;
    }

    final remoteSigned = await _api.isSignedToday();
    if (remoteSigned) {
      await _markSignedToday();
    }

    return remoteSigned;
  }

  Future<SignResult> signNow() async {
    final result = await _api.signIn();

    if (result.success) {
      await _markSignedToday();
    }

    return result;
  }

  /// App 启动时调用。
  ///
  /// 遍历「多账号管理」里的全部账号逐个签到；当前登录账号若未加入多账号
  /// 管理，也会一并签到，保证不会比单账号逻辑更少签。
  /// 签到过程会临时切换登录态，结束后恢复成用户原本的登录态。
  /// 成功签到后当天不会再次请求；网络失败不记录成功，下次启动自动重试。
  Future<AutoSignOutcome> runStartupAutoSign() async {
    if (!await getAutoSignEnabled()) {
      return const AutoSignOutcome.skipped('自动签到未开启');
    }

    final sessions = await _signTargets();
    if (sessions.isEmpty) {
      return const AutoSignOutcome.skipped('未登录');
    }

    // 记录原登录态，全部签完后恢复，避免切号影响用户当前会话。
    final originalAuth = _api.auth;
    final originalSaltkey = _api.saltkey;
    final originalUid = _api.currentUid;

    final results = <AutoSignAccountResult>[];
    try {
      for (final session in sessions) {
        results.add(await _signSession(session));
      }
    } finally {
      if (originalAuth != null &&
          originalAuth.isNotEmpty &&
          originalSaltkey != null &&
          originalSaltkey.isNotEmpty) {
        await _api.applySession(
          auth: originalAuth,
          saltkey: originalSaltkey,
          uid: originalUid,
        );
      } else {
        // 原本就是未登录状态，批量签到后要还原成未登录。
        await _api.clearCredentials();
      }
    }

    return _buildOutcome(results);
  }

  /// 需要签到的账号：多账号列表 + 当前登录态（按 auth 去重）。
  Future<List<SavedAccount>> _signTargets() async {
    final targets = <SavedAccount>[];
    final seenAuth = <String>{};

    for (final account in await AccountService.list()) {
      if (account.auth.isEmpty || !seenAuth.add(account.auth)) {
        continue;
      }
      targets.add(account);
    }

    final auth = _api.auth;
    final saltkey = _api.saltkey;
    if (auth == null ||
        auth.isEmpty ||
        saltkey == null ||
        saltkey.isEmpty ||
        !seenAuth.add(auth)) {
      return targets;
    }

    targets.add(
      SavedAccount(
        uid: _api.currentUid ?? '',
        username: '当前账号',
        avatar: '',
        level: '',
        auth: auth,
        saltkey: saltkey,
      ),
    );

    return targets;
  }

  Future<AutoSignAccountResult> _signSession(SavedAccount session) async {
    final name = session.displayName;

    // notify: false —— 批量切号不逐个通知界面，结束后统一恢复登录态。
    await _api.applySession(
      auth: session.auth,
      saltkey: session.saltkey,
      uid: session.uid,
      notify: false,
    );

    try {
      if (await syncTodayStatus()) {
        return AutoSignAccountResult(
          name: name,
          attempted: false,
          success: true,
          message: '今日已签到',
        );
      }

      final result = await signNow();
      return AutoSignAccountResult(
        name: name,
        attempted: true,
        success: result.success,
        message: result.message,
      );
    } catch (e) {
      return AutoSignAccountResult(
        name: name,
        attempted: true,
        success: false,
        message: '自动签到失败：$e',
      );
    }
  }

  AutoSignOutcome _buildOutcome(List<AutoSignAccountResult> results) {
    final attempted = results.where((r) => r.attempted).toList();
    final failed = attempted.where((r) => !r.success).toList();

    if (attempted.isEmpty) {
      return AutoSignOutcome(
        attempted: false,
        success: true,
        message: results.length == 1
            ? '今日已签到'
            : '${results.length} 个账号今日均已签到',
        accounts: results,
      );
    }

    final ok = results.length - failed.length;
    if (failed.isEmpty) {
      return AutoSignOutcome(
        attempted: true,
        success: true,
        message: results.length == 1
            ? results.first.message
            : '$ok 个账号签到成功',
        accounts: results,
      );
    }

    final names = failed.map((r) => r.name).join('、');
    return AutoSignOutcome(
      attempted: true,
      success: false,
      message: '$ok/${results.length} 个账号签到成功，失败：$names',
      accounts: results,
    );
  }

  /// 今天已成功签到的账号 auth 集合。
  Future<Set<String>> _signedAuthsToday() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_lastSignDateKey) != _todayKey()) {
      return <String>{};
    }

    final raw = prefs.getString(_lastSignAuthsKey);
    if (raw == null || raw.isEmpty) {
      return <String>{};
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.map((e) => '$e').toSet();
      }
    } catch (_) {
      // 数据损坏时按“今天没签过”处理，交给远端状态兜底。
    }

    return <String>{};
  }

  Future<void> _markSignedToday() async {
    final auth = _api.auth;
    if (auth == null || auth.isEmpty) {
      return;
    }

    final today = _todayKey();
    final prefs = await SharedPreferences.getInstance();
    final auths = prefs.getString(_lastSignDateKey) == today
        ? await _signedAuthsToday()
        : <String>{};
    auths.add(auth);

    await prefs.setString(_lastSignDateKey, today);
    await prefs.setString(_lastSignAuthsKey, jsonEncode(auths.toList()));
  }

  String _todayKey() {
    final now = DateTime.now();
    final month = now.month.toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    return '${now.year}-$month-$day';
  }
}
