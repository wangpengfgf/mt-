import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/blacklist_service.dart';
import '../widgets/app_state_view.dart';
import 'account/user_profile_page.dart';

/// 个人小黑屋：合并展示「个人 + 服务端」黑名单，支持移出、清空、同步。
class BlacklistPage extends StatefulWidget {
  const BlacklistPage({super.key});

  @override
  State<BlacklistPage> createState() => _BlacklistPageState();
}

class _BlacklistPageState extends State<BlacklistPage> {
  final _service = BlacklistService.instance;

  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onChanged);
    _sync(force: false);
  }

  @override
  void dispose() {
    _service.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _sync({required bool force}) async {
    if (_syncing) return;
    setState(() => _syncing = true);
    final error =
        force ? await _service.sync() : await _service.syncIfNeeded();
    if (!mounted) return;
    setState(() => _syncing = false);
    if (error != null) _toast(error);
  }

  Future<void> _remove(BlacklistEntry entry) async {
    if (entry.source == 'server') {
      await _service.removeServer(entry.uid);
      _toast('已从本地移除（服务端下次同步会重新拉取）');
    } else {
      await _service.removeLocal(entry.uid);
      _toast('已移出黑名单');
    }
  }

  Future<void> _confirmClearLocal() async {
    if (_service.local.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空个人名单'),
        content: const Text('确定清空本机保存的个人黑名单吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _service.clearLocal();
    _toast('已清空个人名单');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _avatarUrl(String uid) =>
      '${ApiService.baseUrl}/uc_server/avatar.php?uid=$uid&size=middle';

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final entries = _service.all;
    return Scaffold(
      appBar: AppBar(
        title: const Text('个人小黑屋'),
        actions: [
          if (_syncing)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            IconButton(
              tooltip: '同步服务端黑名单',
              onPressed: () => _sync(force: true),
              icon: const Icon(Icons.sync_rounded),
            ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onLongPress: _confirmClearLocal,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
              child: Text(
                '共 ${_service.size} 人'
                '（个人 ${_service.local.length} · 服务端 ${_service.server.length}）'
                '，长按此处清空个人名单',
                style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
              ),
            ),
          ),
          Expanded(
            child: entries.isEmpty
                ? const AppStateView.empty(
                    icon: Icons.block_outlined,
                    title: '黑名单是空的',
                    message: '在用户主页拉黑后，其帖子与回复会被隐藏',
                  )
                : ListView.separated(
                    itemCount: entries.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final e = entries[index];
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: colors.surfaceContainerHighest,
                          backgroundImage: CachedNetworkImageProvider(
                            _avatarUrl(e.uid),
                          ),
                        ),
                        title: Text(
                          e.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          'UID ${e.uid} · '
                          '${e.source == 'server' ? '服务端' : '个人'}',
                        ),
                        trailing: TextButton(
                          onPressed: () => _remove(e),
                          child: const Text('移出'),
                        ),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => UserProfilePage(uid: e.uid),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
