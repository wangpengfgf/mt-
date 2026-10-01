import 'package:flutter/material.dart';

import '../../services/ai/ai_agent.dart';
import '../../services/ai/ai_client.dart';
import '../../services/ai/ai_config.dart';
import '../../services/ai/ai_session_store.dart';
import 'ai_config_page.dart';
import 'ai_session_list_page.dart';

/// AI 助手对话页。
///
/// 核心是把论坛接口以「工具」形式交给大模型：
///   用户提问 → 模型决定调哪个工具 → 本地执行 → 结果回灌 → 循环 → 输出答案。
class AiChatPage extends StatefulWidget {
  const AiChatPage({super.key, this.sessionId, this.freshSession = false});

  /// 已有会话 id；为空表示尚未归属会话，首条消息时自动创建
  final String? sessionId;

  /// 从会话列表「新建会话」进入的空会话标记
  final bool freshSession;

  @override
  State<AiChatPage> createState() => _AiChatPageState();
}

class _ChatItem {
  final String text;
  final bool isUser;
  final bool isSystem;

  const _ChatItem(this.text, {this.isUser = false, this.isSystem = false});
}

class _AiChatPageState extends State<AiChatPage> {
  static const int _maxContextMessages = 40;

  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _history = <AiMsg>[];
  final _items = <_ChatItem>[];

  String? _sessionId;
  bool _freshSession = false;
  bool _busy = false;
  String _status = '';
  bool _inited = false;

  @override
  void initState() {
    super.initState();
    _sessionId = widget.sessionId;
    _freshSession = widget.freshSession;
    _bootstrap();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final sid = _sessionId;
    if (sid != null && sid.isNotEmpty) {
      final saved = await AiSessionStore.loadMessages(sid);
      for (final m in saved) {
        if (m.internal) continue;
        if (_isInternalNoise(m.content)) continue;
        _history.add(m);
        if (m.role == 'user') {
          _items.add(_ChatItem(m.content, isUser: true));
        } else if (m.role == 'assistant' && m.content.isNotEmpty) {
          _items.add(_ChatItem(m.content));
        }
      }
    }
    _inited = true;
    _welcome();
    if (mounted) setState(() {});
    _scrollToBottom();
  }

  /// 旧会话文件里没有 internal 标志的内部轮消息，靠内容特征过滤。
  bool _isInternalNoise(String c) {
    if (c.isEmpty) return false;
    if (c.startsWith('工具执行结果如下：')) return true;
    if (c.startsWith('你刚才的输出是调用计划而不是最终回答。')) return true;
    if (c.startsWith('请基于以上真实数据回答用户')) return true;
    return false;
  }

  void _welcome() {
    if (!AiConfig.isConfigured) {
      _items.add(const _ChatItem(
        '还没配置模型。请点右上角「配置」填好接口地址、API Key 和模型名称。',
        isSystem: true,
      ));
      return;
    }
    _items.add(const _ChatItem(
      '我是接了这个论坛接口的助手。可以让我：\n'
      '· 查最新帖、搜关键词\n'
      '· 读某个帖子的正文和评论\n'
      '· 总结、提炼观点\n'
      '· 直接回帖（需要你明确说「帮我回复」）',
      isSystem: true,
    ));
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _persistSession() async {
    final sid = _sessionId;
    if (sid == null || sid.isEmpty) return;
    if (_history.isEmpty) {
      if (_freshSession) await AiSessionStore.deleteSession(sid);
      return;
    }
    final title = AiSessionStore.titleFromMessages(_history);
    await AiSessionStore.saveMessages(sid, _history, title);
  }

  void _trimHistory() {
    if (_history.length <= _maxContextMessages) return;
    var start = _history.length - _maxContextMessages;
    while (start < _history.length && _history[start].role != 'user') {
      start++;
    }
    if (start >= _history.length) start = _history.length ~/ 2;
    _history.removeRange(0, start);
  }

  Future<void> _send() async {
    if (_busy) {
      _toast('还在处理上一条，稍等');
      return;
    }
    final text = _input.text.trim();
    if (text.isEmpty) return;
    if (!AiConfig.isConfigured) {
      _toast('请先点右上角「配置」填好模型参数');
      return;
    }
    if (!_inited) return;

    _input.clear();
    setState(() {
      _items.add(_ChatItem(text, isUser: true));
      _busy = true;
      _status = '正在思考…';
    });
    _scrollToBottom();

    _history.add(AiMsg.user(text));
    if (_sessionId == null || _sessionId!.isEmpty) {
      _sessionId = await AiSessionStore.createSession();
      _freshSession = true;
    }

    String answer;
    try {
      answer = await AiAgent.run(
        _history,
        onStatus: (s) {
          if (mounted) setState(() => _status = s);
        },
      );
    } catch (e) {
      answer = '出错了：${e.runtimeType} $e';
    }

    _history.add(AiMsg.assistant(answer));
    _trimHistory();
    await _persistSession();

    if (!mounted) return;
    setState(() {
      _items.add(_ChatItem(answer));
      _busy = false;
      _status = '';
    });
    _scrollToBottom();
  }

  Future<void> _clearChat() async {
    if (_busy) {
      _toast('还在处理上一条，稍等');
      return;
    }
    if (_sessionId != null && _sessionId!.isNotEmpty && _history.isNotEmpty) {
      await _persistSession();
    }
    final id = await AiSessionStore.createSession();
    if (!mounted) return;
    setState(() {
      _history.clear();
      _items.clear();
      _sessionId = id;
      _freshSession = true;
    });
    _welcome();
    setState(() {});
    _scrollToBottom();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _fillQuick(String text) {
    _input.text = text;
    _input.selection = TextSelection.fromPosition(
      TextPosition(offset: text.length),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 助手'),
        actions: [
          IconButton(
            tooltip: '新对话',
            icon: const Icon(Icons.add_comment_outlined),
            onPressed: _clearChat,
          ),
          IconButton(
            tooltip: '历史会话',
            icon: const Icon(Icons.history_rounded),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AiSessionListPage()),
            ).then((_) => _reloadSession()),
          ),
          IconButton(
            tooltip: '配置',
            icon: const Icon(Icons.tune_rounded),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AiConfigPage()),
              );
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              itemCount: _items.length + (_busy ? 1 : 0),
              itemBuilder: (context, index) {
                if (index == _items.length) {
                  return _ThinkingBubble(status: _status);
                }
                return _Bubble(item: _items[index]);
              },
            ),
          ),
          _quickBar(colors),
          _inputBar(colors),
        ],
      ),
    );
  }

  Future<void> _reloadSession() async {
    // 从会话列表返回后不主动切换会话，仅刷新可能在配置页改动的状态
    if (mounted) setState(() {});
  }

  Widget _quickBar(ColorScheme colors) {
    const quicks = [
      ['最新帖', '看看论坛最新发布的帖子，挑 3 个值得看的简单说说'],
      ['我的帖', '我最近发过哪些帖子？有人说我什么吗'],
      ['版块', '论坛有哪些版块，各自是干什么的'],
      ['通知', '我有哪些新通知或私信'],
    ];
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final q in quicks)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ActionChip(
                label: Text(q[0]),
                onPressed: _busy ? null : () => _fillQuick(q[1]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _inputBar(ColorScheme colors) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border(top: BorderSide(color: colors.outlineVariant)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: const InputDecoration(
                  hintText: '问点什么，或让我帮你读帖子 / 总结…',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 6),
            IconButton.filled(
              onPressed: _busy ? null : _send,
              icon: const Icon(Icons.send_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.item});

  final _ChatItem item;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (item.isSystem) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 20),
        child: Text(
          item.text,
          textAlign: TextAlign.center,
          style: TextStyle(color: colors.onSurfaceVariant, fontSize: 13),
        ),
      );
    }
    final isUser = item.isUser;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.82,
        ),
        decoration: BoxDecoration(
          color: isUser ? colors.primary : colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
        ),
        child: SelectableText(
          item.text,
          style: TextStyle(
            color: isUser ? colors.onPrimary : colors.onSurface,
            fontSize: 14.5,
            height: 1.4,
          ),
        ),
      ),
    );
  }
}

class _ThinkingBubble extends StatelessWidget {
  const _ThinkingBubble({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Text(
              status.isEmpty ? '正在思考…' : status,
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
