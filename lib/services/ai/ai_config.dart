import 'package:shared_preferences/shared_preferences.dart';

/// AI 配置存储。
///
/// 统一管理大模型接入参数、生成参数、提示词、自动回复策略与功能开关。
/// 键名与 Java 版 `AiConfigManager` 保持一致，便于两端行为对齐。
class AiConfig {
  AiConfig._();

  // ---- 模型接入 ----
  static const String _kBaseUrl = 'ai_base_url';
  static const String _kApiKey = 'ai_api_key';
  static const String _kModel = 'ai_model';
  static const String _kSystemPrompt = 'ai_system_prompt';
  static const String _kTemperature = 'ai_temperature';
  static const String _kSendTemperature = 'ai_send_temperature';
  static const String _kMaxTokens = 'ai_max_tokens';
  static const String _kTimeout = 'ai_timeout';

  // ---- 自动回复 ----
  static const String _kAutoReplyEnabled = 'auto_reply_enabled';
  static const String _kAutoReplySilent = 'auto_reply_silent';
  static const String _kAutoReplyInterval = 'auto_reply_interval';
  static const String _kAutoReplyPrompt = 'auto_reply_prompt';
  static const String _kAutoReplyMaxPerRun = 'auto_reply_max_per_run';
  static const String _kAutoReplyMinLength = 'auto_reply_min_length';
  static const String _kAutoReplyDryRun = 'auto_reply_dry_run';
  static const String _kAutoReplyOnlyOwn = 'auto_reply_only_own';
  static const String _kAutoUnlockHidden = 'auto_unlock_hidden';
  static const String _kUnlockOnView = 'unlock_on_view';
  static const String _kUnlockReplyTemplate = 'unlock_reply_template';

  // ---- 自动签到 ----
  static const String _kAutoSignIn = 'auto_sign_in_enabled';

  // ---- 对话记忆 ----
  static const String _kMemory = 'ai_memory_json';

  static const String defaultBaseUrl = 'https://api.openai.com/v1';
  static const String defaultModel = 'gpt-4o-mini';

  static const String defaultSystemPrompt =
      '你是 MT 论坛（bbs.binmt.cc）的资深技术助手，专注于 Android 逆向、'
      'APK 修改、Smali、脱壳、脱敏、协议分析等话题。'
      '回答要简洁、务实、直给结论，不要客套。'
      '涉及技术问题请给出可执行的具体步骤或代码片段。';

  static const String defaultReplyPrompt =
      '你是 MT 论坛的活跃成员，正在浏览论坛帖子并参与讨论。\n'
      '请根据帖子标题和正文内容，写一条自然、有信息量的回复。\n'
      '要求：\n'
      '1. 直接针对帖子内容，不要泛泛而谈\n'
      '2. 语气像真实论坛用户，不要过度客套、不要用「楼主」开头\n'
      '3. 长度控制在 15 到 80 字之间\n'
      '4. 不要输出任何解释、前缀、引号或 markdown 标记，只输出回复正文\n'
      '5. 如果帖子内容无法理解或涉及违规话题，只输出：[[SKIP]]';

  static SharedPreferences? _prefs;

  static Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  static SharedPreferences get _p {
    final p = _prefs;
    if (p == null) {
      throw StateError('AiConfig 未初始化，请先调用 AiConfig.init()');
    }
    return p;
  }

  // ==================== 模型接入 ====================

  static String get baseUrl {
    final v = _p.getString(_kBaseUrl);
    return (v == null || v.trim().isEmpty) ? defaultBaseUrl : v.trim();
  }

  static Future<void> setBaseUrl(String? v) =>
      _p.setString(_kBaseUrl, (v ?? '').trim());

  static String get apiKey => _p.getString(_kApiKey) ?? '';

  static Future<void> setApiKey(String? v) =>
      _p.setString(_kApiKey, (v ?? '').trim());

  static String get model {
    final v = _p.getString(_kModel);
    return (v == null || v.trim().isEmpty) ? defaultModel : v.trim();
  }

  static Future<void> setModel(String? v) =>
      _p.setString(_kModel, (v ?? '').trim());

  static String get systemPrompt {
    final v = _p.getString(_kSystemPrompt);
    return (v == null || v.isEmpty) ? defaultSystemPrompt : v;
  }

  static Future<void> setSystemPrompt(String? v) =>
      _p.setString(_kSystemPrompt, v ?? '');

  static double get temperature => _p.getDouble(_kTemperature) ?? 0.7;

  static Future<void> setTemperature(double v) =>
      _p.setDouble(_kTemperature, v);

  /// 是否在请求体里发送 temperature。
  /// 部分模型 / 中转只接受 temperature=1，发送自定义值会直接 400。
  static bool get sendTemperature => _p.getBool(_kSendTemperature) ?? true;

  static Future<void> setSendTemperature(bool v) =>
      _p.setBool(_kSendTemperature, v);

  static int get maxTokens => _p.getInt(_kMaxTokens) ?? 8192;

  static Future<void> setMaxTokens(int v) => _p.setInt(_kMaxTokens, v);

  static int get timeoutSeconds => _p.getInt(_kTimeout) ?? 60;

  static Future<void> setTimeoutSeconds(int v) => _p.setInt(_kTimeout, v);

  /// 配置是否可用（有地址 + 有 key + 有模型）
  static bool get isConfigured =>
      baseUrl.isNotEmpty && apiKey.isNotEmpty && model.isNotEmpty;

  // ==================== 自动回复 ====================

  static bool get autoReplyEnabled => _p.getBool(_kAutoReplyEnabled) ?? false;

  static Future<void> setAutoReplyEnabled(bool v) =>
      _p.setBool(_kAutoReplyEnabled, v);

  /// 静默模式：不弹通知、不在界面提示，后台悄悄回复
  static bool get silentMode => _p.getBool(_kAutoReplySilent) ?? true;

  static Future<void> setSilentMode(bool v) =>
      _p.setBool(_kAutoReplySilent, v);

  /// 轮询间隔，秒
  static int get replyInterval {
    final v = _p.getInt(_kAutoReplyInterval) ?? 300;
    return v < 30 ? 30 : v;
  }

  static Future<void> setReplyInterval(int v) =>
      _p.setInt(_kAutoReplyInterval, v < 30 ? 30 : v);

  static String get replyPrompt {
    final v = _p.getString(_kAutoReplyPrompt);
    return (v == null || v.isEmpty) ? defaultReplyPrompt : v;
  }

  static Future<void> setReplyPrompt(String? v) =>
      _p.setString(_kAutoReplyPrompt, v ?? '');

  /// 单轮最多回复几条，防止刷屏
  static int get maxReplyPerRun {
    final v = _p.getInt(_kAutoReplyMaxPerRun) ?? 3;
    return v < 1 ? 1 : v;
  }

  static Future<void> setMaxReplyPerRun(int v) =>
      _p.setInt(_kAutoReplyMaxPerRun, v < 1 ? 1 : v);

  static int get minReplyLength {
    final v = _p.getInt(_kAutoReplyMinLength) ?? 8;
    return v < 2 ? 2 : v;
  }

  static Future<void> setMinReplyLength(int v) =>
      _p.setInt(_kAutoReplyMinLength, v < 2 ? 2 : v);

  /// 演练模式：只生成不发送，用于调试提示词
  static bool get dryRun => _p.getBool(_kAutoReplyDryRun) ?? false;

  static Future<void> setDryRun(bool v) => _p.setBool(_kAutoReplyDryRun, v);

  /// 只回复自己帖子里的评论（更安全）
  static bool get onlyReplyOwnThreads => _p.getBool(_kAutoReplyOnlyOwn) ?? true;

  static Future<void> setOnlyReplyOwnThreads(bool v) =>
      _p.setBool(_kAutoReplyOnlyOwn, v);

  /// 自动回复模式：true = 解锁隐藏内容；false = 回复自己帖子的新评论
  static bool get unlockMode => _p.getBool(_kAutoUnlockHidden) ?? true;

  static Future<void> setUnlockMode(bool v) =>
      _p.setBool(_kAutoUnlockHidden, v);

  /// 进入帖子详情页时自动回复解锁隐藏内容
  static bool get unlockOnView => _p.getBool(_kUnlockOnView) ?? true;

  static Future<void> setUnlockOnView(bool v) =>
      _p.setBool(_kUnlockOnView, v);

  /// 自定义解锁回复模板：{title} 会被替换为帖子标题关键词，空则用内置模板池
  static String get unlockReplyTemplate =>
      _p.getString(_kUnlockReplyTemplate) ?? '';

  static Future<void> setUnlockReplyTemplate(String? v) =>
      _p.setString(_kUnlockReplyTemplate, (v ?? '').trim());

  // ==================== 自动签到 ====================

  static bool get autoSignInEnabled => _p.getBool(_kAutoSignIn) ?? true;

  static Future<void> setAutoSignInEnabled(bool v) =>
      _p.setBool(_kAutoSignIn, v);

  // ==================== 记忆 ====================

  static String get memory => _p.getString(_kMemory) ?? '[]';

  static Future<void> setMemory(String? json) =>
      _p.setString(_kMemory, json == null ? '[]' : json);
}
