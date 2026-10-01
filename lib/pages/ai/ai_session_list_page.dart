import 'package:flutter/material.dart';

import '../../services/ai/ai_session_store.dart';
import 'ai_chat_page.dart';

/// AI 会话列表页（Codex 风格）。
///
/// 列出全部会话，支持新建 / 点击续聊 / 长按删除。
class AiSessionListPage extends StatefulWidget {
  const AiSessionListPage({super.key});

  @override
  State<AiSessionListPage> createState() => _AiSessionListPageState();
}

class _AiSessionListPageState extends State<AiSessionListPage> {
  List<AiSession> _sessions = const [];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final list = await AiSessionStore.listSessions();
    if (!mounted) return;
    setState(() => _sessions = list);
  }

  Future<void> _newSession() async {
    final id = await AiSessionStore.createSession();
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AiChatPage(sessionId: id, freshSession: true),
      ),
    );
    _refresh();
  }

  Future<void> _open(AiSession s) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => AiChatPage(sessionId: s.id)),
    );
    _refresh();
  }

  Future<void> _confirmDelete(AiSession s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除会话'),
        content: Text('删除「${s.title}」？对话将无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await AiSessionStore.deleteSession(s.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已删除')),
    );
    _refresh();
  }

  Future<void> _rename(AiSession s) async {
    final controller = TextEditingController(text: s.title);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名会话'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    await AiSessionStore.renameSession(s.id, name);
    _refresh();
  }

  String _formatTime(int ms) {
    if (ms <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v < 10 ? '0$v' : '$v';
    return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('历史会话'),
        actions: [
          TextButton(onPressed: _newSession, child: const Text('新建会话')),
        ],
      ),
      body: _sessions.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  '还没有会话。点右上角「新建会话」开始。\n也可以在聊天页里直接开聊，会自动保存。',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 20),
              itemCount: _sessions.length,
              itemBuilder: (context, index) {
                final s = _sessions[index];
                return Card(
                  margin: const EdgeInsets.only(top: 8),
                  child: ListTile(
                    title: Text(
                      s.title.isEmpty ? '新会话' : s.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${s.messageCount} 条消息 · ${_formatTime(s.updatedAt)}',
                    ),
                    onTap: () => _open(s),
                    onLongPress: () => _confirmDelete(s),
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) {
                        if (v == 'rename') _rename(s);
                        if (v == 'delete') _confirmDelete(s);
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'rename', child: Text('重命名')),
                        PopupMenuItem(value: 'delete', child: Text('删除')),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
