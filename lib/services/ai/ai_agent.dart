import 'dart:convert';

import 'ai_client.dart';
import 'ai_config.dart';
import 'ai_log.dart';
import 'forum_tools.dart';

/// AI Agent。
///
/// 把论坛接口以「工具」形式交给大模型：
///   用户提问 → 模型决定调哪个工具 → 本地执行 ForumTools → 结果回灌模型 → 循环 → 输出答案。
///
/// 移植自 Java 版 `AiChatActivity`，并保留对不支持 function calling 的中转的
/// 文本协议兼容层（文本调用行 / 自然语言调用意图 / 括号调用清单三种识别路径）。
class AiAgent {
  AiAgent._();

  /// 标准模式最多几轮工具调用，防止模型空转
  static const int maxToolRounds = 6;

  /// 兼容模式最多几轮
  static const int maxCompatRounds = 3;

  /// 执行一轮对话，返回最终回答文本。
  ///
  /// [history] 为当前会话完整上下文（已包含本轮 user 消息）。
  /// 调用方负责把最终回答追加进 history。
  static Future<String> run(
    List<AiMsg> history, {
    void Function(String status)? onStatus,
  }) async {
    final systemPrompt = AiConfig.systemPrompt;
    final tools = ForumTools.definitions();

    final msgs = <AiMsg>[
      AiMsg.system(_buildSystemPrompt(systemPrompt)),
      ...history,
    ];

    final calledTools = <String>[];
    final failedTools = <String>[];

    for (var round = 0; round < maxToolRounds; round++) {
      onStatus?.call(round == 0 ? '正在思考…' : '正在整理第 $round 轮结果…');

      final result = await AiClient.chat(msgs, tools);
      if (!result.success) {
        AiLog.e('ai-chat', '模型调用失败: ${result.error}');
        return '调用模型失败：${result.error}';
      }

      final toolCalls = result.toolCalls;
      if (toolCalls == null || toolCalls.isEmpty) {
        final content = result.content;

        // 兼容层：模型把「打算调用哪些工具」写成了文字，却没真的发起调用。
        if (calledTools.isEmpty) {
          final compat = await _runCompatToolCalls(
            content,
            systemPrompt,
            history,
            onStatus,
            calledTools,
            failedTools,
          );
          if (compat != null) return compat;
        }

        if (content.isEmpty) {
          final uniq = _uniqToolNames(calledTools);
          AiLog.e(
            'ai-chat',
            '模型返回空内容。finish_reason=${result.finishReason} '
                'reasonLen=${result.reasoningContent.length} '
                'promptTokens=${result.promptTokens} '
                'completionTokens=${result.completionTokens} 已调用工具=$uniq',
          );

          // 情况一：首轮就空答且 finish_reason=length —— max_tokens 不够，放宽重试
          if (result.finishReason == 'length') {
            AiLog.i('ai-chat', 'finish_reason=length，放宽 max_tokens 重试一次');
            final retry = await AiClient.chat(msgs, tools, maxTokensOverride: 8192);
            if (retry.success) {
              final rt = retry.toolCalls;
              if (rt != null && rt.isNotEmpty) {
                msgs.add(_buildAssistantToolCallMsg(retry));
                for (var i = 0; i < rt.length; i++) {
                  msgs.add(await _executeOneToolCall(
                    rt,
                    i,
                    onStatus,
                    calledTools,
                    failedTools,
                  ));
                }
                continue;
              }
              if (retry.content.isNotEmpty) return retry.content;
            }
          }

          if (calledTools.isEmpty) {
            final compat = await _runCompatToolCalls(
              content,
              systemPrompt,
              history,
              onStatus,
              calledTools,
              failedTools,
            );
            if (compat != null) return compat;

            // 兜底：模型既不说话也不调工具 —— 改用纯文本协议再走一轮
            final fb = await _runTextFallback(systemPrompt, history, onStatus);
            if (fb != null) return fb;

            if (result.finishReason.isEmpty) {
              return '模型没有返回内容。\n'
                  '链路诊断：服务端有响应，但没给出结束原因（finish_reason 为空）。\n'
                  '这通常意味着：\n'
                  '1. 你用的是推理型模型（deepseek-reasoner / o1 这类），'
                  '只输出思考不输出回答，或它本身不支持工具调用\n'
                  '2. 中转没有把 tools 参数转发给上游\n'
                  '3. 模型名填错\n'
                  '建议先改成 gpt-4o-mini / deepseek-chat 试一次。\n'
                  '完整请求体与响应体已写进「AI 配置 → 运行日志」（ai-req / ai-resp）。';
            }
            return '模型没有返回内容。\n'
                '链路诊断：请求已发出且服务端有响应'
                '（finish_reason=${result.finishReason}，'
                'prompt_tokens=${result.promptTokens}，'
                'completion_tokens=${result.completionTokens}）。\n'
                '常见原因：\n'
                '1. 该模型不支持 function calling（换成 gpt-4o / deepseek-chat 等）\n'
                '2. 模型名填错，或中转不转发 tools 参数\n'
                '3. max_tokens 太小被截断（当前 ${AiConfig.maxTokens}）\n'
                '已把完整请求体与响应体写进「运行日志」（ai-req / ai-resp），'
                '把那段发我即可定位。';
          }
          return '模型读到了数据但没有给出回答。\n调用过的工具：$uniq'
              '${failedTools.isEmpty ? '' : '\n其中失败的：${_uniqToolNames(failedTools)}'}';
        }

        // content 非空、兼容层也没接住：疑似调用计划 → 转文本协议重试
        if (_looksLikeToolPlan(content)) {
          AiLog.i('ai-chat', 'content 疑似调用计划（无工具调用），转文本协议重试');
          final fb = await _runTextFallback(systemPrompt, history, onStatus);
          if (fb != null) return fb;
        }
        return content;
      }

      msgs.add(_buildAssistantToolCallMsg(result));
      for (var i = 0; i < toolCalls.length; i++) {
        msgs.add(await _executeOneToolCall(
          toolCalls,
          i,
          onStatus,
          calledTools,
          failedTools,
        ));
      }
    }

    AiLog.e('ai-chat', '工具调用超过 $maxToolRounds 轮');
    return '模型连续调用了太多次工具，已停止。\n'
        '已调用：${calledTools.join(', ')}\n'
        '可以换个更具体的说法再问一次。';
  }

  // ==================== 文本协议回退 ====================

  /// 不带 tools，把工具清单写进 system prompt，靠模型输出 {"tool":...} 行驱动调用。
  static Future<String?> _runTextFallback(
    String systemPrompt,
    List<AiMsg> history,
    void Function(String)? onStatus,
  ) async {
    onStatus?.call('该模型不支持工具调用，改用文本模式重试…');

    final msgs = <AiMsg>[
      AiMsg.system(
        '${systemPrompt.isEmpty ? AiConfig.defaultSystemPrompt : systemPrompt}'
        '\n\n${ForumTools.textToolCatalog()}',
      ),
      ...history,
    ];

    final called = <String>[];
    for (var i = 0; i < maxToolRounds; i++) {
      final r = await AiClient.chat(msgs, null, maxTokensOverride: 8192);
      if (!r.success || r.content.isEmpty) return null;

      final calls = _parseTextToolCalls(r.content);
      if (calls == null || calls.isEmpty) {
        final done = AiMsg.assistant(r.content);
        done.internal = true;
        msgs.add(done);
        return r.content;
      }

      final plan = AiMsg.assistant(r.content);
      plan.internal = true;
      msgs.add(plan);

      final results = StringBuffer('工具执行结果如下：\n');
      for (final c in calls) {
        final name = '${c['tool'] ?? c['name'] ?? ''}';
        if (name.isEmpty) continue;
        final args = _asArgMap(c['args'] ?? c['arguments']);
        onStatus?.call('正在调用 $name …');
        var toolResult = await _safeExecute(name, args);
        called.add(name);
        AiLog.i('ai-tool-text', '$name -> ${AiLog.clip(toolResult, 300)}');
        results.writeln('【$name】\n${AiLog.clip(toolResult, 4000)}');
      }
      final resultMsg = AiMsg.user(results.toString());
      resultMsg.internal = true;
      msgs.add(resultMsg);
    }
    AiLog.e('ai-chat', '文本模式工具调用超过上限，已调用=${_uniqToolNames(called)}');
    return null;
  }

  // ==================== 兼容工具调用 ====================

  /// 把自然语言里的调用意图真正跑一遍，结果回灌让模型作答。
  static Future<String?> _runCompatToolCalls(
    String firstContent,
    String systemPrompt,
    List<AiMsg> history,
    void Function(String)? onStatus,
    List<String> calledTools,
    List<String> failedTools,
  ) async {
    final inferred = _inferToolCalls(firstContent, history);
    if (inferred == null || inferred.isEmpty) return null;
    var calls = inferred;

    onStatus?.call('识别到工具调用意图，正在执行…');
    AiLog.i('ai-compat', '从文本推断出调用: ${jsonEncode(calls)}');

    final msgs = <AiMsg>[
      AiMsg.system(
        '${systemPrompt.isEmpty ? AiConfig.defaultSystemPrompt : systemPrompt}'
        '\n\n${ForumTools.textToolCatalog()}',
      ),
      ...history,
    ];
    final first = AiMsg.assistant(firstContent);
    first.internal = true;
    msgs.add(first);

    for (var round = 0; round < maxCompatRounds; round++) {
      final results = StringBuffer('工具执行结果如下：\n');
      for (final c in calls) {
        final name = '${c['tool'] ?? ''}';
        if (name.isEmpty) continue;
        final args = _asArgMap(c['args']);
        onStatus?.call('正在调用 $name …');
        final toolResult = await _safeExecute(name, args);
        calledTools.add(name);
        if (toolResult.contains('"error"')) failedTools.add(name);
        AiLog.i('ai-compat', '$name -> ${AiLog.clip(toolResult, 300)}');
        results.writeln('【$name】\n${AiLog.clip(toolResult, 4000)}');
      }
      final feedback = AiMsg.user(
        '${results.toString()}\n请基于以上真实数据回答用户，不要再输出工具调用计划。',
      );
      feedback.internal = true;
      msgs.add(feedback);

      final r = await AiClient.chat(msgs, null, maxTokensOverride: 8192);
      if (!r.success || r.content.isEmpty) return null;

      final respMsg = AiMsg.assistant(r.content);
      respMsg.internal = true;
      msgs.add(respMsg);

      final next = _inferToolCalls(r.content, history);
      if (next == null || next.isEmpty) {
        // 内部轮次的「我要继续调用」计划文本不是最终回答
        if (_looksLikeToolPlan(r.content)) {
          AiLog.i('ai-compat', '内部轮次输出疑似调用计划，重申文本协议后继续');
          final restate = AiMsg.user(
            '你刚才的输出是调用计划而不是最终回答。'
            '请直接输出工具调用行：{"tool":"工具名","args":{"参数名":"值"}}，'
            '或基于已有数据给出面向用户的最终回答，不要再描述计划。',
          );
          restate.internal = true;
          msgs.add(restate);
          continue;
        }
        return r.content;
      }
      calls = next;
    }
    AiLog.e('ai-compat', '兼容模式轮数用尽，已调用=${_uniqToolNames(calledTools)}');
    return null;
  }

  /// 从模型纯文本回复里抽取 {"tool":"x","args":{...}} 形式的调用。
  static List<Map<String, dynamic>>? _parseTextToolCalls(String text) {
    if (text.isEmpty) return null;
    final out = <Map<String, dynamic>>[];

    // 标签式调用：<tool_call>调用 search_forum {"keyword":"x"}
    for (final m in _tagCallRe.allMatches(text)) {
      final nm = m.group(1);
      if (nm == null || nm.isEmpty) continue;
      final o = <String, dynamic>{'tool': nm};
      final rawArgs = m.group(2);
      if (rawArgs != null && rawArgs.isNotEmpty) {
        final s2 = rawArgs.indexOf('{');
        if (s2 >= 0) {
          final e2 = rawArgs.lastIndexOf('}');
          if (e2 > s2) {
            try {
              o['args'] = jsonDecode(rawArgs.substring(s2, e2 + 1));
            } catch (_) {}
          }
        }
      }
      out.add(o);
    }

    for (final raw in text.split(RegExp(r'\r?\n'))) {
      var line = raw.trim();
      if (line.isEmpty) continue;
      line = line.replaceAll('```json', '').replaceAll('```', '').trim();
      final s = line.indexOf('{');
      final e = line.lastIndexOf('}');
      if (s < 0 || e <= s) continue;
      try {
        final o = jsonDecode(line.substring(s, e + 1));
        if (o is Map && (o.containsKey('tool') || o.containsKey('name'))) {
          final nm = '${o['tool'] ?? o['name'] ?? ''}';
          if (nm.isNotEmpty) out.add(o.cast<String, dynamic>());
        }
      } catch (_) {
        // 不是工具调用行，跳过
      }
    }

    final dedup = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final o in out) {
      final nm = '${o['tool'] ?? o['name'] ?? ''}';
      if (seen.contains(nm)) continue;
      seen.add(nm);
      dedup.add(o);
    }
    return dedup.isEmpty ? null : dedup;
  }

  /// 从模型自然语言回复里推断它想调用哪些工具。
  static List<Map<String, dynamic>>? _inferToolCalls(
    String text,
    List<AiMsg> history,
  ) {
    if (text.isEmpty) return null;
    final lower = text.toLowerCase();

    // 形式零：编号式括号调用清单
    final bracket = _parseBracketCallList(text);
    if (bracket != null && bracket.isNotEmpty) return bracket;

    // 形式一：已经是 JSON 调用行
    final jsonCalls = _parseTextToolCalls(text);
    if (jsonCalls != null && jsonCalls.isNotEmpty) {
      _backfillKeywordFromQuestion(jsonCalls, history);
      return jsonCalls;
    }

    var hasIntent = false;
    for (final w in _intentWords) {
      if (lower.contains(w.toLowerCase())) {
        hasIntent = true;
        break;
      }
    }

    final out = <Map<String, dynamic>>[];
    final hit = <String>{};
    for (final alias in _toolAliases) {
      final canonical = alias.first;
      if (hit.contains(canonical)) continue;

      var idx = -1;
      var matched = '';
      for (var i = 1; i < alias.length; i++) {
        final a = alias[i].toLowerCase();
        final p = lower.indexOf(a);
        if (p >= 0 && (idx < 0 || p < idx)) {
          idx = p;
          matched = a;
        }
      }
      if (idx < 0) continue;

      final strong = _isInvocationLike(text, idx, matched.length);
      final soft = hasIntent && text.length < 700;
      if (!strong && !soft) continue;

      hit.add(canonical);
      out.add({
        'tool': canonical,
        'args': _extractArgs(canonical, _window(text, idx, matched.length)),
      });
      if (hit.length >= 4) break;
    }
    if (out.isNotEmpty) _backfillKeywordFromQuestion(out, history);
    return out.isEmpty ? null : out;
  }

  /// 扫描 `search_forum(keyword="x")` 这种括号调用清单。
  static List<Map<String, dynamic>>? _parseBracketCallList(String text) {
    if (text.length > 2500) return null;
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final m in _bracketCallRe.allMatches(text)) {
      final tool = (m.group(1) ?? '').toLowerCase();
      final key = (m.group(2) ?? '').toLowerCase();
      final val = (m.group(3) ?? '').trim();
      if (!_knownTools.contains(tool)) continue;
      if (_isJunkKeyword(val)) continue;
      final dk = '$tool|$key|$val';
      if (seen.contains(dk)) continue;
      seen.add(dk);
      out.add({
        'tool': tool,
        'args': {key: val},
      });
      if (out.length >= 4) break;
    }
    return out.isEmpty ? null : out;
  }

  /// 调用里缺 keyword 时，从用户最后的提问中抓关键词兜底。
  static void _backfillKeywordFromQuestion(
    List<Map<String, dynamic>> calls,
    List<AiMsg> history,
  ) {
    try {
      String? lastQ;
      for (var i = history.length - 1; i >= 0; i--) {
        final m = history[i];
        if (m.role == 'user' && m.content.isNotEmpty) {
          lastQ = m.content.trim();
          break;
        }
      }
      if (lastQ == null || lastQ.isEmpty) return;

      for (final c in calls) {
        final tool = '${c['tool'] ?? c['name'] ?? ''}';
        if (tool != 'search_forum') continue;

        final args = _asArgMap(c['args']);
        final kw = '${args['keyword'] ?? ''}';
        if (kw.isNotEmpty && !_isJunkKeyword(kw)) {
          // 模型给纯英文词、提问里能切出中文核心段时用中文覆盖
          if (RegExp(r"^[A-Za-z][A-Za-z0-9'&+.\-]*$").hasMatch(kw)) {
            final cn = _extractCnCore(lastQ);
            if (!_isJunkKeyword(cn)) {
              AiLog.i(
                'ai-compat',
                '关键词覆盖(search_forum): 模型英文词"$kw"改用提问中文核心词: $cn',
              );
              args['keyword'] = cn;
              c['args'] = args;
            }
          }
          continue;
        }

        var cand = _extractCnCore(lastQ);
        if (_isJunkKeyword(cand)) {
          cand = _match(lastQ, r'["“]([^"”]{2,20})["”]');
        }
        if (_isJunkKeyword(cand)) {
          cand = _match(lastQ, r'([A-Za-z0-9][A-Za-z0-9_+#.\-]{2,30})');
        }
        if (_isJunkKeyword(cand)) {
          cand = _match(lastQ, r'([\u4e00-\u9fa5]{2,8})');
        }
        if (!_isJunkKeyword(cand)) {
          args['keyword'] = cand;
          AiLog.i(
            'ai-compat',
            '关键词兜底(search_forum): 模型给的"$kw"不可用，改用提问核心词: $cand',
          );
        }
        c['args'] = args;
      }
    } catch (_) {}
  }

  /// 关键词是否为垃圾（空 / 太短 / 纯标点序号 / 英文通用功能词）。
  static bool _isJunkKeyword(String? s) {
    if (s == null) return true;
    final t = s.trim();
    if (t.isEmpty) return true;
    if (t.length < 2 && !RegExp(r'[\u4e00-\u9fa5]').hasMatch(t)) return true;
    if (RegExp(r'^[\d.\-\s]+$').hasMatch(t)) return true;
    if (RegExp(r'^[.\-—_~\s]+$').hasMatch(t)) return true;
    return _kwStop.contains(t.toLowerCase());
  }

  /// 从中文提问里抠核心词：先剔意图/功能词，再取最长纯中文段。
  static String? _extractCnCore(String? q) {
    if (q == null) return null;
    var s = q;
    for (final w in _questionStopWords) {
      s = s.replaceAll(w, '|');
    }
    String? best;
    String? single;
    for (var seg in s.split(RegExp(r'\|+'))) {
      seg = seg.trim();
      if (seg.isEmpty) continue;
      if (!RegExp(r'^[\u4e00-\u9fa5]+$').hasMatch(seg)) continue;
      if (seg.length == 1) {
        single ??= seg;
        continue;
      }
      if (best == null || seg.length > best.length) best = seg;
    }
    if (best != null && best.length <= 12) return best;
    return (best == null && single != null) ? single : null;
  }

  /// 工具名附近 ±160 字符的窗口。
  static String _window(String text, int idx, int nameLen) {
    final from = (idx - 80).clamp(0, text.length);
    final to = (idx + nameLen + 200).clamp(0, text.length);
    return text.substring(from, to);
  }

  /// 工具名写法像不像「真的在调用」：带括号，或前面紧跟调用动词。
  static bool _isInvocationLike(String text, int idx, int nameLen) {
    final after = text.substring((idx + nameLen).clamp(0, text.length));
    final at = after.trimLeft();
    if (at.startsWith('(') || at.startsWith('（')) return true;
    if (at.startsWith('=')) return true;

    final before = text.substring((idx - 14).clamp(0, idx), idx).toLowerCase();
    return before.contains('调用') ||
        before.contains('call') ||
        before.contains('执行') ||
        before.contains('invoke');
  }

  /// 按工具类型从窗口文本里抠参数。
  static Map<String, dynamic> _extractArgs(String tool, String w) {
    final a = <String, dynamic>{};
    try {
      switch (tool) {
        case 'search_forum':
          var kw = _match(
            w,
            r'(?:keyword|kw|关键词|搜索词|srchtxt)[=:：]\s*["“]([^"”]{1,40})["”]',
          );
          kw ??= _match(
            w,
            r'(?:keyword|kw|关键词|搜索词|srchtxt)[=:：]\s*([\u4e00-\u9fa5A-Za-z0-9_]{1,40})',
          );
          if (kw == null) {
            // 引号词两轮逐试：单词候选优先，双词短语次之，3 词以上长短语判废
            for (final m in _quotedRe.allMatches(w)) {
              final cand = (m.group(1) ?? '').trim();
              if (cand.contains(' ')) continue;
              if (RegExp(r'[，。、！？；：,.!?;:]').hasMatch(cand)) continue;
              if (_isJunkKeyword(cand)) continue;
              kw = cand;
              break;
            }
            if (kw == null) {
              for (final m in _quotedRe.allMatches(w)) {
                final cand = (m.group(1) ?? '').trim();
                if (_isJunkKeyword(cand)) continue;
                if (_longEnglishPhraseRe.hasMatch(cand)) continue;
                kw = cand;
                break;
              }
            }
          }
          if (kw != null && _isJunkKeyword(kw)) kw = null;
          if (kw != null && _longEnglishPhraseRe.hasMatch(kw)) kw = null;
          if (kw != null) a['keyword'] = kw;
          final ob = _match(w, r'(lastpost|dateline|replies)');
          if (ob != null) a['orderby'] = ob;
          break;
        case 'list_threads':
          final fid = _match(
            w,
            r'(?:fid|forum_?id|版块(?:id|ID)?)[=:：]?\s*["“]?(\d{1,6})',
          );
          if (fid != null) a['fid'] = fid;
          break;
        case 'get_thread':
        case 'get_replies':
          var tid = _match(
            w,
            r'(?:tid|thread_?id|帖子(?:id|ID)?|主题(?:id|ID)?)[=:：]?\s*["“]?(\d{1,9})',
          );
          tid ??= _match(w, r'thread-(\d{1,9})');
          if (tid != null) a['tid'] = tid;
          final mr = _match(w, r'(?:max_replies|最多)[=:：]?\s*(\d{1,3})');
          if (mr != null) a['max_replies'] = mr;
          break;
        case 'get_notices':
          final ty = _match(w, r'(pm|mypost|interactive|system)');
          if (ty != null) a['type'] = ty;
          break;
        case 'get_user_profile':
          final uid = _match(
            w,
            r'(?:uid|用户(?:id|ID)?)[=:：]?\s*["“]?(\d{1,9})',
          );
          if (uid != null) a['uid'] = uid;
          break;
        case 'post_reply':
          final tid = _match(
            w,
            r'(?:tid|帖子(?:id|ID)?)[=:：]?\s*["“]?(\d{1,9})',
          );
          if (tid != null) a['tid'] = tid;
          final msg = _match(
            w,
            r'(?:message|回复内容|内容)[=:：]\s*["“]([^"”]{1,200})["”]',
          );
          if (msg != null) a['message'] = msg;
          break;
      }
      final page = _match(w, r'(?:page|页码)[=:：]?\s*(\d{1,4})');
      if (page != null && !a.containsKey('page')) a['page'] = page;
    } catch (_) {}
    return a;
  }

  static String? _match(String src, String regex) {
    try {
      final m = RegExp(regex, caseSensitive: false).firstMatch(src);
      return m?.group(1)?.trim();
    } catch (_) {
      return null;
    }
  }

  /// 判断模型输出像不像「工具调用计划」而不是最终回答。
  static bool _looksLikeToolPlan(String text) {
    if (text.isEmpty || text.length > 1500) return false;
    final lower = text.toLowerCase();
    if (lower.contains('搜索结果') ||
        lower.contains('执行结果') ||
        lower.contains('以下是') ||
        lower.contains('总结如下') ||
        lower.contains('为您整理')) {
      return false;
    }
    var planWords = 0;
    for (final w in _planMarkers) {
      if (lower.contains(w)) planWords++;
    }
    var hasToolName = false;
    for (final alias in _toolAliases) {
      for (var i = 1; i < alias.length; i++) {
        if (lower.contains(alias[i].toLowerCase())) {
          hasToolName = true;
          break;
        }
      }
      if (hasToolName) break;
    }
    return planWords >= 2 || (planWords >= 1 && hasToolName);
  }

  // ==================== 执行工具 ====================

  static Future<AiMsg> _executeOneToolCall(
    List<dynamic> toolCalls,
    int i,
    void Function(String)? onStatus,
    List<String> calledTools,
    List<String> failedTools,
  ) async {
    final call = toolCalls[i];
    if (call is! Map) {
      return AiMsg.tool('call_$i', '', '{"error":"空 tool_call"}');
    }
    final callId = '${call['id'] ?? 'call_$i'}';
    final fn = call['function'];
    final name = (fn is Map) ? '${fn['name'] ?? ''}' : '';
    final argsRaw = (fn is Map) ? '${fn['arguments'] ?? '{}'}' : '{}';
    final args = _asArgMap(_tryDecode(argsRaw));

    onStatus?.call('正在调用 $name …');
    final toolResult = await _safeExecute(name, args);

    calledTools.add(name);
    if (toolResult.contains('"error"')) failedTools.add(name);
    AiLog.i('ai-tool', '$name -> ${AiLog.clip(toolResult, 300)}');

    return AiMsg.tool(callId, name, toolResult);
  }

  static Future<String> _safeExecute(
    String name,
    Map<String, dynamic> args,
  ) async {
    try {
      final r = await ForumTools.execute(name, args);
      return r.isEmpty ? '{"error":"工具返回空"}' : r;
    } catch (e) {
      return '{"error":"${e.runtimeType}"}';
    }
  }

  static AiMsg _buildAssistantToolCallMsg(AiResult result) {
    final m = AiMsg.assistant(result.content);
    m.toolCallsJson = jsonEncode(result.toolCalls);
    return m;
  }

  static String _buildSystemPrompt(String base) {
    return '${base.isEmpty ? AiConfig.defaultSystemPrompt : base}'
        '\n\n当前时间：${_nowText()}'
        '\n你可以调用提供的工具去读取论坛真实内容。'
        '需要看帖子内容时先调工具拿数据，不要凭空编造。'
        '调用工具前想清楚需要哪些参数，一次尽量拿全。'
        '只有在用户明确要求「回复」「发评论」时才调用 post_reply，'
        '并且要基于真实读到的帖子内容写回复，禁止编造楼层或用户。';
  }

  // ==================== 辅助 ====================

  static Map<String, dynamic> _asArgMap(dynamic v) {
    if (v is Map) return v.cast<String, dynamic>();
    if (v is String) {
      final d = _tryDecode(v);
      if (d is Map) return d.cast<String, dynamic>();
    }
    return <String, dynamic>{};
  }

  static dynamic _tryDecode(String s) {
    try {
      return jsonDecode(s.isEmpty ? '{}' : s);
    } catch (_) {
      return null;
    }
  }

  static String _uniqToolNames(List<String> names) {
    if (names.isEmpty) return '无';
    final out = <String>[];
    for (final n in names) {
      if (n.isNotEmpty && !out.contains(n)) out.add(n);
    }
    return out.isEmpty ? '无' : out.join(', ');
  }

  static String _nowText() {
    final t = DateTime.now();
    String two(int v) => v < 10 ? '0$v' : '$v';
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }

  // ==================== 常量表 ====================

  static final RegExp _tagCallRe = RegExp(
    r'<tool_call>(?:调用\s*)?([a-z_]+)\s*([\{（(][^\n]{1,300}?)?[\}）)]?',
    caseSensitive: false,
  );

  static final RegExp _bracketCallRe = RegExp(
    r'([a-z_]{3,30})\s*\(\s*([a-zA-Z_]{2,20})\s*=\s*["“]([^"”]{1,40})["”][^)]{0,120}\)',
    caseSensitive: false,
  );

  static final RegExp _quotedRe = RegExp(r'["“]([^"”]{1,40})["”]');

  static final RegExp _longEnglishPhraseRe = RegExp(
    r"^[A-Za-z][A-Za-z'&+.\-]*(\s+[A-Za-z][A-Za-z'&+.\-]*){2,}$",
  );

  static const Set<String> _knownTools = {
    'my_threads',
    'get_notices',
    'list_threads',
    'search_forum',
    'list_forums',
    'get_thread',
    'get_replies',
    'get_user_profile',
    'post_reply',
    'unlock_hidden',
  };

  /// 工具名 + 常见别名，用于从自然语言回复里识别调用意图
  static const List<List<String>> _toolAliases = [
    ['my_threads', 'my_threads', 'mythreads', 'my threads', '我的帖子', '我的主题'],
    ['get_notices', 'get_notices', 'getnotices', 'notices', 'notice', '通知', '私信'],
    ['list_threads', 'list_threads', 'listthreads', 'latest threads', '最新帖', '最新帖子'],
    [
      'search_forum',
      'search_forum',
      'searchforum',
      'search for',
      'search the',
      'search posts',
      'search several keywords',
      'search',
      'find posts',
      'look up',
      '搜帖',
      '搜一下',
      '搜帖子',
      '搜索帖子',
      '搜索',
      '搜',
    ],
    ['list_forums', 'list_forums', 'listforums', '版块列表', '论坛版块'],
    ['get_thread', 'get_thread', 'getthread', '帖子详情', '帖子正文'],
    ['get_replies', 'get_replies', 'getreplies', '回复列表'],
    ['get_user_profile', 'get_user_profile', 'getuserprofile', '用户资料'],
    ['post_reply', 'post_reply', 'postreply', '发表回复'],
    ['unlock_hidden', 'unlock_hidden', 'unlockhidden', '解锁隐藏', '回复可见', '解锁隐藏内容'],
  ];

  /// 意图词：出现这些词 + 工具名，才认定模型是「想调用」而不是「在解释」
  static const List<String> _intentWords = [
    '我要', '我需要', '我应该', '我来', '打算', '计划', '调用', '检查', '查询', '获取',
    'i should', 'i need', 'i will', "i'll", 'let me', 'call the', 'use the', 'i can',
    'i need to', 'i want to', "i'm going to", 'i will do', "let's search", "i'll do",
    '我来搜', '我来查', '马上搜', '马上查', '我去搜', '我去查', '试搜', '试查',
    '搜一下', '查一下', '直接搜', '先搜', '再搜', '搜他', '找一下', '找找',
    '搜搜', '搜他的',
  ];

  /// 计划特征词
  static const List<String> _planMarkers = [
    "i'll", 'i will', 'let me', 'i need to', 'i want to', "i'm going to",
    'first, i', 'multiple searches', 'several keywords',
    '调用', '搜索', '先查', '再查', '接下来我会',
    '我来搜', '我来查', '马上搜', '马上查', '我去搜', '我去查', '试搜', '试查',
    '搜一下', '查一下', '搜搜', '搜他的', '找一下', '找找', '马上执行',
  ];

  /// 英文通用功能词黑名单
  static const Set<String> _kwStop = {
    'search', 'searching', 'searches', 'keyword', 'keywords', 'posts', 'post',
    'forum', 'forums', 'thread', 'threads', 'several', 'multiple', 'parallel',
    'first', 'second', 'then', 'next', 'need', 'want', 'about', 'related',
    'topics', 'topic', 'high', 'quality', 'summarize', 'summarizing', 'user',
    'users', 'wants', 'lets', 'will', 'with', 'sort', 'sorted', 'sorting',
    'recent', 'latest', 'replies', 'game', 'games', 'cracking', 'modding',
  };

  /// 提问里的意图/功能词黑名单
  static const List<String> _questionStopWords = [
    '总结', '归纳', '概括', '汇总', '整理', '介绍', '讲解', '帮我', '麻烦', '请',
    '找找', '找一下', '看看', '查看', '列出', '推荐', '搜索', '查找', '检索',
    '论坛', '社区', '帖子', '主题', '教程', '相关', '关于', '高质量', '优质',
    '内容', '分析', '回复', '评论',
    '其他', '另外', '哪些', '什么', '怎么',
    '里', '中', '上', '下', '的', '了', '是', '有', '和', '与', '或', '吧',
    '呢', '呀', '个', '这', '那', '些', '想', '要', '需', '一', '二', '三',
  ];
}
