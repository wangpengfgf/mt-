import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../services/account_service.dart';
import '../../services/api_service.dart';

/// 多账号管理页：保存当前账号、一键切换、删除已存账号。
class AccountSwitchPage extends StatefulWidget {
  const AccountSwitchPage({super.key});

  @override
  State<AccountSwitchPage> createState() => _AccountSwitchPageState();
}

class _AccountSwitchPageState extends State<AccountSwitchPage> {
  final _api = ApiService.instance;

  List<SavedAccount> _accounts = const [];
  String? _activeUid;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final accounts = await AccountService.list();
    final active = await AccountService.activeUid();
    if (!mounted) return;
    setState(() {
      _accounts = accounts;
      _activeUid = active;
      _loading = false;
    });
  }

  Future<void> _saveCurrent() async {
    if (_busy) return;
    if (!_api.isLoggedIn) {
      _toast('当前未登录，无法保存');
      return;
    }
    setState(() => _busy = true);
    final ok = await AccountService.saveCurrent();
    if (!mounted) return;
    setState(() => _busy = false);
    _toast(ok ? '已保存当前账号' : '保存失败：未取得账号信息');
    await _load();
  }

  Future<void> _switchTo(SavedAccount account) async {
    if (_busy) return;
    if (account.uid == _activeUid && _api.isLoggedIn) {
      _toast('已经是当前账号');
      return;
    }
    setState(() => _busy = true);
    final ok = await AccountService.switchTo(account.uid);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      _toast('已切换到 ${account.displayName}');
      Navigator.pop(context, true);
    } else {
      _toast('切换失败');
    }
  }

  Future<void> _remove(SavedAccount account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除账号'),
        content: Text('确定删除已保存的「${account.displayName}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await AccountService.remove(account.uid);
    await _load();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('多账号管理'),
        actions: [
          TextButton(
            onPressed: _busy ? null : _saveCurrent,
            child: const Text('保存当前'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
              children: [
                Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: ListTile(
                    leading: const Icon(Icons.person_add_alt_1_rounded),
                    title: const Text('保存当前登录账号'),
                    subtitle: const Text('把当前登录态存为快照，之后可一键切回'),
                    trailing: _busy
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.add_rounded),
                    onTap: _busy ? null : _saveCurrent,
                  ),
                ),
                if (_accounts.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 48),
                    child: Center(
                      child: Text(
                        '还没有已保存的账号。\n登录后点右上角「保存当前」添加。',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    ),
                  )
                else
                  for (final a in _accounts)
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: colors.surfaceContainerHighest,
                          backgroundImage: a.avatar.isNotEmpty
                              ? CachedNetworkImageProvider(a.avatar)
                              : null,
                          child: a.avatar.isEmpty
                              ? const Icon(Icons.person_rounded)
                              : null,
                        ),
                        title: Text(a.displayName),
                        subtitle: Text(
                          'UID ${a.uid}'
                          '${a.level.isEmpty ? '' : ' · ${a.level}'}'
                          '${a.uid == _activeUid ? ' · 当前' : ''}',
                        ),
                        trailing: IconButton(
                          tooltip: '删除',
                          icon: Icon(
                            Icons.delete_outline_rounded,
                            color: colors.error,
                          ),
                          onPressed: () => _remove(a),
                        ),
                        onTap: () => _switchTo(a),
                      ),
                    ),
              ],
            ),
    );
  }
}
