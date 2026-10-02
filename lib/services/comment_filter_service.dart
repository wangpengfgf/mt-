import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 过滤规则的类型，两种方式互斥，同一时间只有一种生效。
enum CommentFilterMode {
  /// 按关键词匹配，支持精确/模糊两种比对。
  keyword,

  /// 按正则表达式匹配。
  regex,
}

/// 评论与回复通知共用的本地过滤设置。
///
/// 过滤只发生在客户端展示层，不会向论坛提交屏蔽规则，也不会改变论坛账号。
class CommentFilterService extends ChangeNotifier {
  CommentFilterService._();

  static final CommentFilterService instance = CommentFilterService._();

  static const _commentsEnabledKey = 'comment_filter_comments_enabled';
  static const _noticesEnabledKey = 'comment_filter_notices_enabled';
  static const _modeKey = 'comment_filter_mode';
  static const _keywordsKey = 'comment_filter_keywords';
  static const _regexPatternsKey = 'comment_filter_regex_patterns';
  static const _keywordContainsEnabledKey =
      'comment_filter_keyword_contains_enabled';
  static const _matchLengthLimitEnabledKey =
      'comment_filter_match_length_limit_enabled';
  static const _maxMatchedContentLengthKey =
      'comment_filter_max_matched_content_length';
  static const defaultMaxMatchedContentLength = 20;

  bool _commentsEnabled = false;
  bool _noticesEnabled = false;
  CommentFilterMode _mode = CommentFilterMode.keyword;
  bool _keywordContainsEnabled = false;
  bool _matchLengthLimitEnabled = false;
  int _maxMatchedContentLength = defaultMaxMatchedContentLength;
  List<String> _keywords = const [];
  List<String> _regexPatterns = const [];
  bool _loaded = false;

  /// 已编译的正则缓存，值用 null 表示该表达式无效。
  final Map<String, RegExp?> _regexCache = {};

  bool get commentsEnabled => _commentsEnabled;
  bool get noticesEnabled => _noticesEnabled;
  CommentFilterMode get mode => _mode;
  bool get regexModeEnabled => _mode == CommentFilterMode.regex;
  bool get keywordContainsEnabled => _keywordContainsEnabled;
  bool get fuzzyMatchingEnabled => _keywordContainsEnabled;
  bool get matchLengthLimitEnabled => _matchLengthLimitEnabled;
  int get maxMatchedContentLength => _maxMatchedContentLength;
  List<String> get keywords => List.unmodifiable(_keywords);
  bool get hasKeywords => _keywords.isNotEmpty;
  List<String> get regexPatterns => List.unmodifiable(_regexPatterns);
  bool get hasRegexPatterns => _regexPatterns.isNotEmpty;

  /// 当前生效的方式下是否已配置规则，另一种方式的规则不计入。
  bool get hasRules => regexModeEnabled ? hasRegexPatterns : hasKeywords;

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _commentsEnabled = prefs.getBool(_commentsEnabledKey) ?? false;
    _noticesEnabled = prefs.getBool(_noticesEnabledKey) ?? false;
    _keywordContainsEnabled =
        prefs.getBool(_keywordContainsEnabledKey) ?? false;
    _matchLengthLimitEnabled =
        prefs.getBool(_matchLengthLimitEnabledKey) ?? false;
    _maxMatchedContentLength =
        (prefs.getInt(_maxMatchedContentLengthKey) ??
                defaultMaxMatchedContentLength)
            .clamp(1, 500)
        .toInt();
    _keywords = _normalize(prefs.getStringList(_keywordsKey) ?? const []);
    _mode = prefs.getString(_modeKey) == CommentFilterMode.regex.name
        ? CommentFilterMode.regex
        : CommentFilterMode.keyword;
    _regexPatterns = _normalize(
      prefs.getStringList(_regexPatternsKey) ?? const [],
    );
    _regexCache.clear();
    _loaded = true;
    notifyListeners();
  }

  /// 切换过滤方式，切换后另一种方式的规则不再参与匹配。
  Future<void> setMode(CommentFilterMode value) async {
    _mode = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modeKey, value.name);
  }

  Future<void> setCommentsEnabled(bool value) async {
    _commentsEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_commentsEnabledKey, value);
  }

  Future<void> setNoticesEnabled(bool value) async {
    _noticesEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_noticesEnabledKey, value);
  }

  Future<void> setKeywordContainsEnabled(bool value) async {
    _keywordContainsEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keywordContainsEnabledKey, value);
  }

  Future<void> setFuzzyMatchingEnabled(bool value) {
    return setKeywordContainsEnabled(value);
  }

  Future<void> setMatchLengthLimitEnabled(bool value) async {
    _matchLengthLimitEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_matchLengthLimitEnabledKey, value);
  }

  Future<void> setMaxMatchedContentLength(int value) async {
    _maxMatchedContentLength = value.clamp(1, 500).toInt();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _maxMatchedContentLengthKey,
      _maxMatchedContentLength,
    );
  }

  Future<void> setKeywordsFromText(String value) async {
    _keywords = _normalize(value.split(RegExp(r'[,，;；\n\r]+')));
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_keywordsKey, _keywords);
  }

  /// 追加单个屏蔽词。已存在（忽略大小写）时返回 false。
  Future<bool> addKeyword(String value) async {
    final keyword = value.trim();
    if (keyword.isEmpty) return false;
    final exists = _keywords.any(
      (item) => item.toLowerCase() == keyword.toLowerCase(),
    );
    if (exists) return false;
    _keywords = _normalize([..._keywords, keyword]);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_keywordsKey, _keywords);
    return true;
  }

  /// 按行拆分正则表达式。
  ///
  /// 正则里可以出现逗号、分号（如 a{2,3}），所以不能用关键词那套分隔符。
  static List<String> parseRegexPatterns(String value) {
    return value
        .split(RegExp(r'[\n\r]+'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }

  /// 找出第一条无法编译的正则，全部合法时返回 null。
  static String? findInvalidRegex(Iterable<String> patterns) {
    for (final pattern in patterns) {
      try {
        RegExp(pattern);
      } on FormatException {
        return pattern;
      }
    }
    return null;
  }

  Future<void> setRegexPatternsFromText(String value) async {
    _regexPatterns = _normalize(parseRegexPatterns(value));
    _regexCache.clear();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_regexPatternsKey, _regexPatterns);
  }

  /// 按当前生效的方式匹配，命中任意一条规则即需要隐藏。
  bool matches(String value) {
    return regexModeEnabled ? matchesRegex(value) : matchesKeyword(value);
  }

  bool matchesKeyword(String value) {
    if (_keywords.isEmpty || value.trim().isEmpty) return false;
    final normalized = _normalizeMatchText(value);
    final matched = _keywords.any(
      (keyword) {
        final normalizedKeyword = _normalizeMatchText(keyword);
        return _keywordContainsEnabled
            ? normalized.contains(normalizedKeyword)
            : normalized == normalizedKeyword;
      },
    );
    if (!matched) return false;
    if (!_matchLengthLimitEnabled) return true;
    final contentLength = value.replaceAll(RegExp(r'\s+'), '').runes.length;
    return contentLength <= _maxMatchedContentLength;
  }

  /// 正则匹配：直接对原始内容匹配，不再压缩空白。
  ///
  /// 忽略大小写，且 ^ 和 $ 按行生效，方便逐行写规则。
  bool matchesRegex(String value) {
    if (_regexPatterns.isEmpty || value.trim().isEmpty) return false;
    final matched = _regexPatterns.any((pattern) {
      final regex = _regexFor(pattern);
      return regex != null && regex.hasMatch(value);
    });
    if (!matched) return false;
    if (!_matchLengthLimitEnabled) return true;
    final contentLength = value.replaceAll(RegExp(r'\s+'), '').runes.length;
    return contentLength <= _maxMatchedContentLength;
  }

  /// 编译并缓存正则；编译失败时返回 null，跳过该条而不影响其它规则。
  RegExp? _regexFor(String pattern) {
    if (_regexCache.containsKey(pattern)) return _regexCache[pattern];
    RegExp? regex;
    try {
      regex = RegExp(pattern, caseSensitive: false, multiLine: true);
    } on FormatException {
      regex = null;
    }
    _regexCache[pattern] = regex;
    return regex;
  }

  List<String> _normalize(Iterable<String> values) {
    final result = <String>[];
    final seen = <String>{};
    for (final value in values) {
      final keyword = value.trim();
      final key = keyword.toLowerCase();
      if (keyword.isNotEmpty && seen.add(key)) result.add(keyword);
    }
    return result;
  }

  String _normalizeMatchText(String value) {
    return value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  }
}
