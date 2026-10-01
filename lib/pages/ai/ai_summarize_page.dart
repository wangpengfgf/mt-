import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/ai/ai_client.dart';
import '../../services/ai/ai_config.dart';
import '../../services/ai/ai_log.dart';
import '../../services/ai/forum_tools.dart';

/// AI 一键总结页：帖子内容 + 评论区 → AI 总结。
///
/// 流程：
///  1. 拉取帖子详情（含正文与隐藏内容）
///  2. 检测隐藏内容是否锁定：锁定 → 用内置/自定义模板回帖解锁 → 回读确认
///  3. 拉取评论（最多 80 条）
///  4. 组包交给 AI 一次生成结构化总结
class AiSummarizePage extends StatefulWidget {
  const AiSummarizePage({super.key, required this.tid, this.title});

  final String tid;
  final String? title;

  @override
  State<AiSummarizePage> createState() => _AiSummarizePageState();
}

class _AiSummarizePageState extends State<AiSummarizePage> {
  String _status = '正在拉取帖子…';
  String _summary = '';
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _setStatus(String s) {
    if (mounted) setState(() => _status = s);
  }

  Future<void> _start() async {
    if (_running) return;
    if (widget.tid.trim().isEmpty) {
      setState(() => _status = '缺少帖子 ID，无法总结');
      return;
    }
    if (!AiConfig.isConfigured) {
      setState(() => _status = '请先配置 AI 模型参数（AI 助手 → 右上角配置）');
      return;
    }
    setState(() {
      _running = true;
      _summary = '';
    });

    try {
      var raw = await ForumTools.execute('get_thread', {
        'tid': widget.tid,
        'fetch_all': true,
        'max_replies': 80,
      });
      final parsed = _asMap(raw);
      if (parsed == null) {
        _setStatus('拉取失败：返回内容无法解析');
        return;
      }
      Map<String, dynamic> thread = parsed;
      if (thread.containsKey('error')) {
        _setStatus('拉取失败：${thread['error']}');
        return;
      }

      var content = '${thread['content'] ?? ''}';
      final title = (widget.title ?? '${thread['title'] ?? ''}').trim();

      // 隐藏内容锁定检测：解析器仅在「未解锁」时保留门控提示 hidden_hint，
      // 已解锁时隐藏正文会被并入 content。因此 hidden_hint 非空或正文含
      // 门控文案即视为锁定。
      final hint = '${thread['hidden_hint'] ?? ''}';
      final hiddenLocked =
          hint.isNotEmpty || _containsGateWord(content);

      if (hiddenLocked) {
        _setStatus('检测到隐藏内容，正在用模板回帖解锁…');
        final unlockRaw = await ForumTools.execute('unlock_hidden', {
          'tid': widget.tid,
        });
        AiLog.i('ai-summarize', 'unlock_hidden -> ${_clip(unlockRaw, 500)}');
        final unlock = _asMap(unlockRaw);
        if (unlock != null && unlock['success'] == true) {
          _setStatus('解锁成功，正在整理…');
        } else {
          _setStatus('回复已发出，按已获取内容总结');
        }
        // 回读一次，确保拿到最新正文（含已解锁的隐藏内容）。
        try {
          final raw2 = await ForumTools.execute('get_thread', {
            'tid': widget.tid,
            'fetch_all': true,
            'max_replies': 80,
          });
          final thread2 = _asMap(raw2);
          if (thread2 != null && !thread2.containsKey('error')) {
            thread = thread2;
            content = '${thread2['content'] ?? ''}';
          }
        } catch (_) {}
      }

      _setStatus('正在 AI 总结（内容 + 评论区）…');

      final prompt = StringBuffer();
      prompt.write('【帖子标题】${title.isNotEmpty ? title : '${thread['title'] ?? ''}'}\n\n');
      prompt.write('【帖子正文】\n${_clip(content, 6000)}');

      final replies = thread['replies'];
      if (replies is List && replies.isNotEmpty) {
        prompt.write('\n\n【评论区(${replies.length}条)');
        var budget = 12000;
        for (final r in replies) {
          if (r is! Map) continue;
          var line = '${r['author'] ?? '?'}: ${'${r['content'] ?? ''}'.trim()}';
          if (line.length > 300) line = '${line.substring(0, 300)}…';
          if (budget - line.length < 0) break;
          budget -= line.length;
          prompt.write('\n-$line');
        }
        prompt.write('\n');
      }

      const sys =
          '你是论坛帖子总结助手。基于给定的帖子正文与评论区，用中文写一份结构化总结，格式：\n'
          '【一句话总结】…\n【要点】- …\n【隐藏内容】…(如有)\n【评论区氛围/高赞观点】…\n'
          '只依据给定材料，不要编造；材料不足的部分直接说明。';

      final result = await AiClient.simpleChat(sys, prompt.toString());
      if (result == null || result.trim().isEmpty) {
        _setStatus('AI 总结返回为空，稍后重试');
        return;
      }
      if (!mounted) return;
      setState(() {
        _summary = result.trim();
        _status = '总结完成';
      });
    } catch (e) {
      _setStatus('总结失败：${e.runtimeType} $e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _copy() async {
    if (_summary.trim().isEmpty) {
      _toast('暂无内容可复制');
      return;
    }
    await Clipboard.setData(ClipboardData(text: _summary));
    _toast('已复制到剪贴板');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final title = (widget.title ?? '').trim();
    return Scaffold(
      appBar: AppBar(
        title: Text(
          title.isEmpty ? 'AI 总结' : title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (_running)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          IconButton(
            tooltip: '复制',
            icon: const Icon(Icons.copy_rounded),
            onPressed: _copy,
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            color: colors.surfaceContainerLow,
            child: Row(
              children: [
                Icon(Icons.auto_awesome_rounded, size: 16, color: colors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _status,
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
              child: _summary.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 60),
                        child: Text(
                          _running ? '正在生成总结…' : '暂无总结内容',
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      ),
                    )
                  : SelectableText(
                      _summary,
                      style: const TextStyle(fontSize: 15, height: 1.6),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  static Map<String, dynamic>? _asMap(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return null;
    } catch (_) {
      return null;
    }
  }

  static bool _containsGateWord(String text) {
    if (text.isEmpty) return false;
    final t = ForumTools.stripTags(text);
    return t.contains('如果您要查看') ||
        t.contains('请回复') ||
        t.contains(ForumTools.hiddenGateText);
  }

  static String _clip(String s, int max) {
    if (s.isEmpty) return '';
    return s.length > max ? '${s.substring(0, max)}…' : s;
  }
}
