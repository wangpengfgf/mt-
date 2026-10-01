import 'dart:async';
import 'dart:math';

import '../../models/models.dart';
import '../api_service.dart';
import 'ai_client.dart';
import 'ai_config.dart';
import 'ai_log.dart';

/// 自动回复结果回调（运行在调用线程）。
typedef AutoReplyCallback = void Function(
  int replied,
  int skipped,
  String detail,
);

/// 自动回复引擎。
///
/// 两种工作模式（由 [AiConfig.unlockMode] 决定）：
///
///  A. 解锁模式（默认）：
///      进入帖子详情时触发 —— 含「回复可见」的帖子上自动发一条贴合正文的回复并解锁
///
///  B. 评论模式（旧逻辑）：
///      拉取自己的帖子列表 → 逐个读详情 → 找出「别人的新回复」→ 生成回复并发出
///
/// 已处理过的 pid / tid 记入内存集合，避免重复处理。
class AutoReplyEngine {
  AutoReplyEngine._();

  /// 单条待回复任务
  static bool _running = false;

  /// 已处理过的回复 pid，防止重复回复
  static final Set<String> _handledPids = {};

  /// 已尝试解锁过的 tid
  static final Set<String> _handledTids = {};

  /// 论坛防洪限制：两次发帖间隔不得少于该毫秒数（Discuz 默认 15 秒，取 16 秒留余量）
  static const int _minPostIntervalMs = 16000;

  /// 上一次成功/尝试发帖的时间戳，用于全局节流
  static int _lastPostAt = 0;

  static bool get isRunning => _running;

  static void clearHistory() {
    _handledPids.clear();
    _handledTids.clear();
  }

  static bool isHandledTid(String tid) => _handledTids.contains(tid);

  static void markHandledTid(String tid) {
    if (tid.isEmpty) return;
    _handledTids.add(tid);
    if (_handledTids.length > 2000) _handledTids.clear();
  }

  /// 全局节流：确保任意两次发帖间隔不小于 [_minPostIntervalMs]。
  static Future<void> _waitPostThrottle() async {
    while (true) {
      final last = _lastPostAt;
      final elapsed =
          DateTime.now().millisecondsSinceEpoch - last;
      final wait = last <= 0 ? 0 : _minPostIntervalMs - elapsed;
      if (wait <= 0) {
        // 占位，避免并发任务同时通过
        _lastPostAt = DateTime.now().millisecondsSinceEpoch;
        return;
      }
      await Future<void>.delayed(Duration(milliseconds: wait));
    }
  }

  /// 执行一轮自动回复。
  static Future<void> runOnce({AutoReplyCallback? callback}) async {
    if (_running) {
      callback?.call(0, 0, '已有任务在执行');
      return;
    }
    _running = true;

    var replied = 0;
    var skipped = 0;
    final detail = StringBuffer();
    final unlockMode = AiConfig.unlockMode;
    AiLog.i(
      'auto-reply',
      '开始一轮自动回复'
          '${unlockMode ? '（解锁隐藏内容模式）' : '（评论回复模式）'}'
          '${AiConfig.dryRun ? '（演练模式）' : ''}',
    );

    try {
      if (unlockMode) {
        // 解锁模式改为「点开帖才触发」，后台不再自动扫全站。
        _finalize(callback, 0, 0, '解锁模式已改为进帖触发(后台不再扫全站)');
        return;
      }

      final jobs = await _collectJobs(detail);
      if (jobs.isEmpty) {
        _finalize(
          callback,
          0,
          0,
          detail.isEmpty ? '没有发现需要回复的新评论' : detail.toString(),
        );
        return;
      }

      final maxPerRun = AiConfig.maxReplyPerRun;
      final dryRun = AiConfig.dryRun;

      for (final job in jobs) {
        if (replied >= maxPerRun) {
          detail.write('；达到单轮上限 $maxPerRun 条');
          break;
        }

        var text = await _generateReply(job);
        if (text == null || text.isEmpty || text.contains('[[SKIP]]')) {
          skipped++;
          _markHandled(job.pid);
          detail.write('；跳过 ${job.pid}(模型放弃)');
          continue;
        }
        text = _cleanup(text) ?? text;
        if (text.length < AiConfig.minReplyLength) {
          skipped++;
          _markHandled(job.pid);
          detail.write('；跳过 ${job.pid}(太短)');
          continue;
        }

        if (dryRun) {
          replied++;
          _markHandled(job.pid);
          detail.write('；[演练] $text');
          continue;
        }

        final ok = await _sendReply(job, text);
        if (ok) {
          replied++;
          _markHandled(job.pid);
          detail.write('；已回复 ${job.pid}');
          AiLog.i('auto-reply', 'replied to ${job.pid}: $text');
        } else {
          detail.write('；发送失败 ${job.pid}');
        }

        // 控制频率，避免触发风控
        await Future<void>.delayed(
          Duration(milliseconds: 3000 + Random().nextInt(4000)),
        );
      }

      _finalize(callback, replied, skipped, detail.toString());
    } catch (e) {
      AiLog.e('auto-reply', 'runOnce 异常：$e');
      _finalize(callback, replied, skipped, '异常: $e');
    } finally {
      _running = false;
    }
  }

  static void _finalize(
    AutoReplyCallback? cb,
    int replied,
    int skipped,
    String detail,
  ) {
    if (detail.isNotEmpty) {
      AiLog.i(
        'auto-reply',
        '本轮完成：回复 $replied 条，跳过 $skipped 条'
            '${detail.isEmpty ? '' : '｜$detail'}',
      );
    }
    cb?.call(replied, skipped, detail);
  }

  // ==================== 解锁模式 ====================

  /// 进帖触发式解锁：帖子有隐藏内容且未解锁时，自动回帖解锁。
  ///
  /// @return true=本次确实回帖(或演练)且成功; false=不需要解锁/失败
  static Future<bool> tryUnlockOnOpen(ThreadDetail detail) async {
    if (!AiConfig.unlockOnView) return false;
    final tid = detail.tid;
    if (tid.isEmpty) return false;
    if (!ApiService.instance.isLoggedIn) {
      AiLog.e('auto-unlock', '进帖解锁：未登录，跳过 tid=$tid');
      return false;
    }
    final op = detail.posts.isNotEmpty ? detail.posts.first : null;
    if (op == null) return false;
    final hint = op.hiddenHint;
    // 没有隐藏门控提示 => 没有隐藏内容或已解锁
    if (hint == null || hint.isEmpty) return false;
    // 原子认领——连开多帖/重复进入同一帖只回一次
    if (!_claimTid(tid)) return false;

    final text = _buildUnlockText(detail.title);
    if (text.isEmpty) {
      _releaseTid(tid);
      return false;
    }
    if (AiConfig.dryRun) {
      AiLog.i('auto-unlock', '进帖解锁(演练) tid=$tid 回复=$text');
      return true;
    }
    final ok = await _sendUnlockReply(detail, tid, text);
    AiLog.i('auto-unlock', '进帖解锁${ok ? '成功' : '失败'} tid=$tid 回复=$text');
    return ok;
  }

  /// 只解锁某个帖子。返回 true 表示已解锁（或本来就没锁 / 已解锁）。
  static Future<bool> unlockSingleThread(String tid) async {
    if (tid.isEmpty) return false;
    try {
      if (!ApiService.instance.isLoggedIn) {
        AiLog.e('auto-unlock', '未登录，放弃解锁 tid=$tid');
        return false;
      }
      final detail = await ApiService.instance.getThreadDetail(tid);
      final op = detail.posts.isNotEmpty ? detail.posts.first : null;
      final hint = op?.hiddenHint;
      if (hint == null || hint.isEmpty) {
        AiLog.i('auto-unlock', '无隐藏内容或已解锁，跳过 tid=$tid');
        return false;
      }
      final text = _buildUnlockText(detail.title);
      final ok = await _sendUnlockReply(detail, tid, text);
      if (ok) markHandledTid(tid);
      AiLog.i('auto-unlock', 'tid=$tid 结果=$ok 回复=$text');
      return ok;
    } catch (e) {
      AiLog.e('auto-unlock', 'unlockSingleThread 失败：$e');
      return false;
    }
  }

  static bool _claimTid(String tid) {
    if (_handledTids.contains(tid)) return false;
    _handledTids.add(tid);
    return true;
  }

  static void _releaseTid(String tid) => _handledTids.remove(tid);

  /// 隐藏门控提示文本（Flutter 解析器只在「未解锁」时保留该提示）
  static const List<String> _gateWords = [
    '如果您要查看',
    '隐藏内容请',
    '回复可见',
    '需要回复',
  ];

  /// 判断隐藏提示是否仍是门控文案
  static bool isLockedHint(String? hint) {
    if (hint == null || hint.isEmpty) return false;
    for (final w in _gateWords) {
      if (hint.contains(w)) return true;
    }
    return false;
  }

  /// 生成一条用于解锁的回复（本地模板，不调用 AI）。
  static String _buildUnlockText(String title) {
    var kw = title.replaceAll(
      RegExp(r'[\s\p{P}（）【】「」《》，。！？、~·:：]', unicode: true),
      '',
    );
    if (kw.length > 10) kw = kw.substring(0, 10);

    final custom = AiConfig.unlockReplyTemplate;
    if (custom.isNotEmpty) {
      return custom.replaceAll('{title}', kw);
    }

    final pool = kw.isEmpty
        ? <String>[
            '感谢分享，内容看着不错，回复支持一下',
            '谢谢分享，正需要这个，先回复看看',
            '支持一下，感谢分享好资源',
            '感谢楼主分享，回复支持',
          ]
        : <String>[
            '感谢分享「$kw」，正需要这个，回复支持一下',
            '「$kw」看着不错，谢谢分享，下来试试',
            '支持「$kw」，感谢分享，先回复看看',
            '感谢分享「$kw」，正好用得上',
            '「$kw」不错，感谢分享，先收下了',
          ];
    return pool[Random().nextInt(pool.length)];
  }

  /// 发出解锁回复
  static Future<bool> _sendUnlockReply(
    ThreadDetail detail,
    String tid,
    String message,
  ) async {
    try {
      final form = await ApiService.instance.getReplyPostForm(
        tid: tid,
        fid: detail.fid,
      );
      // 详情页偶发解析不到 fid，以回复表单隐藏域里的值为准。
      final fid = detail.fid.isNotEmpty ? detail.fid : form.fid;
      if (fid.isEmpty) {
        AiLog.e('auto-unlock', '拿不到 fid，无法回复 tid=$tid');
        return false;
      }

      await _waitPostThrottle();
      final result = await ApiService.instance.replyThread(
        tid: tid,
        fid: fid,
        noticeauthor: detail.noticeauthor,
        message: message,
        replyForm: form,
      );
      _lastPostAt = DateTime.now().millisecondsSinceEpoch;
      AiLog.i(
        'auto-unlock',
        '回复已提交 tid=$tid fid=$fid 回复内容=$message\n响应=${AiLog.clip(result.message, 400)}',
      );

      if (!result.success) {
        AiLog.e('auto-unlock', '回复被拒 tid=$tid ${AiLog.clip(result.message, 200)}');
        return false;
      }

      // 回读确认解锁
      try {
        final after = await ApiService.instance.getThreadDetail(tid);
        final rawOp = after.posts.isNotEmpty ? after.posts.first : null;
        final unlocked = rawOp?.hiddenHint == null || rawOp!.hiddenHint!.isEmpty;
        AiLog.i('auto-unlock', '回读解锁状态=$unlocked tid=$tid');
        return unlocked;
      } catch (_) {
        return true;
      }
    } catch (e) {
      AiLog.e('auto-unlock', '发送回复异常 tid=$tid $e');
      return false;
    }
  }

  // ==================== 收集待回复任务 ====================

  static Future<List<_Job>> _collectJobs(StringBuffer detail) async {
    final jobs = <_Job>[];
    if (!ApiService.instance.isLoggedIn) {
      detail.write('未登录');
      return jobs;
    }
    final selfUid = ApiService.instance.currentUid;
    if (selfUid == null || selfUid.isEmpty) {
      detail.write('未获取到 UID');
      return jobs;
    }

    final tids = await _findOwnThreadTids(detail);
    if (tids.isEmpty) {
      detail.write('未找到自己的帖子');
      return jobs;
    }

    final onlyOwn = AiConfig.onlyReplyOwnThreads;
    var scanned = 0;

    for (final tid in tids) {
      if (jobs.length >= 8) break; // 单轮最多扫 8 个帖子
      scanned++;
      try {
        final d = await ApiService.instance.getThreadDetail(tid);
        final op = d.posts.isNotEmpty ? d.posts.first : null;
        if (op == null) continue;
        // 若只回复自己帖子，校验楼主是否为本人
        if (onlyOwn && selfUid != (op.authorUid ?? '')) continue;

        final body = op.content;
        final replies = [for (final p in d.posts) if (!p.isOp) p];

        // 倒序遍历，找最新的、非本人的、未处理过的回复
        for (var i = replies.length - 1; i >= 0; i--) {
          final r = replies[i];
          if (r.pid.isEmpty) continue;
          if (selfUid == (r.authorUid ?? '')) continue; // 自己发的不回
          if (_isHandled(r.pid)) continue;

          final content = r.content.trim();
          if (content.length < 2) continue;

          jobs.add(
            _Job(
              tid: tid,
              title: d.title,
              body: body,
              replyAuthor: r.authorName ?? '',
              replyContent: content,
              pid: r.pid,
            ),
          );
          if (jobs.length >= 8) break;
        }
      } catch (e) {
        AiLog.e('auto-reply', '扫描帖子 $tid 失败：$e');
      }
    }

    if (detail.isNotEmpty) detail.write('；');
    detail.write('扫描 $scanned 个帖子，待回复 ${jobs.length} 条');
    return jobs;
  }

  /// 取自己的帖子 tid 列表
  static Future<List<String>> _findOwnThreadTids(StringBuffer detail) async {
    final tids = <String>[];
    try {
      final list = await ApiService.instance.getMyThreads(page: 1);
      for (final t in list) {
        if (t.tid.isNotEmpty) tids.add(t.tid);
      }
    } catch (e) {
      AiLog.e('auto-reply', 'findOwnThreadTids 失败：$e');
    }
    return tids;
  }

  // ==================== 生成回复 ====================

  static Future<String?> _generateReply(_Job job) async {
    final prompt = StringBuffer();
    prompt.writeln('【帖子标题】${job.title}\n');
    if (job.body.isNotEmpty) {
      final body = job.body.length > 3000
          ? job.body.substring(0, 3000)
          : job.body;
      prompt.writeln('【帖子正文】\n$body\n');
    }
    prompt.writeln('【用户 ${job.replyAuthor} 的评论】\n${job.replyContent}\n');
    prompt.write('请针对这条评论写一条回复。');
    return AiClient.simpleChat(AiConfig.replyPrompt, prompt.toString());
  }

  /// 去掉模型可能带上的包裹符号
  static String? _cleanup(String? text) {
    if (text == null) return null;
    var t = text.trim();
    if (t.length > 1 &&
        ((t.startsWith('"') && t.endsWith('"')) ||
            (t.startsWith('「') && t.endsWith('」')) ||
            (t.startsWith('“') && t.endsWith('”')))) {
      t = t.substring(1, t.length - 1).trim();
    }
    t = t.replaceFirst(RegExp(r'^(回复|回答|评论)[:：]\s*'), '');
    t = t.replaceAll('**', '');
    return t.trim();
  }

  // ==================== 发送回复 ====================

  static Future<bool> _sendReply(_Job job, String message) async {
    try {
      final d = await ApiService.instance.getThreadDetail(job.tid);
      final form = await ApiService.instance.getReplyPostForm(
        tid: job.tid,
        fid: d.fid,
        repquotePid: job.pid,
      );
      // 详情页偶发解析不到 fid，以回复表单隐藏域里的值为准。
      final fid = d.fid.isNotEmpty ? d.fid : form.fid;
      if (fid.isEmpty) {
        AiLog.e('auto-reply', '拿不到 fid，放弃回复 tid=${job.tid}');
        return false;
      }
      await _waitPostThrottle();
      final result = await ApiService.instance.replyThread(
        tid: job.tid,
        fid: fid,
        noticeauthor: d.noticeauthor,
        message: message,
        repquotePid: job.pid,
        replyForm: form,
      );
      _lastPostAt = DateTime.now().millisecondsSinceEpoch;
      if (result.success) return true;
      // 服务端偶尔返回模糊提示，这里回读核对一遍
      return await _verifyPublished(job.tid, message);
    } catch (e) {
      AiLog.e('auto-reply', 'sendReply 失败：$e');
      return false;
    }
  }

  /// 回读最新回复列表，确认自己的 UID 下确实出现了这条内容
  static Future<bool> _verifyPublished(String tid, String message) async {
    try {
      final currentUid = ApiService.instance.currentUid;
      if (currentUid == null || currentUid.isEmpty || message.isEmpty) {
        return false;
      }
      var expected = _normalizeReplyText(message);
      if (expected.length > 20) expected = expected.substring(0, 20);
      if (expected.isEmpty) return false;

      for (var page = 1; page <= 2; page++) {
        final d = await ApiService.instance.getThreadDetail(tid, page: page);
        final replies = [for (final p in d.posts) if (!p.isOp) p];
        for (var k = replies.length - 1; k >= 0; k--) {
          final item = replies[k];
          if (currentUid != (item.authorUid ?? '')) continue;
          if (_normalizeReplyText(item.content).contains(expected)) return true;
        }
      }
    } catch (e) {
      AiLog.e('auto-reply', 'verifyPublished 失败：$e');
    }
    return false;
  }

  static String _normalizeReplyText(String text) {
    if (text.isEmpty) return '';
    return text
        .replaceAll(
          RegExp(r'\[attach(?:img)?\]\d+\[/attach(?:img)?\]', caseSensitive: false),
          '',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  // ==================== 历史记录 ====================

  static bool _isHandled(String pid) => _handledPids.contains(pid);

  static void _markHandled(String pid) {
    if (pid.isEmpty) return;
    _handledPids.add(pid);
    if (_handledPids.length > 2000) _handledPids.clear();
  }
}

class _Job {
  final String tid;
  final String title;
  final String body;
  final String replyAuthor;
  final String replyContent;
  final String pid;

  _Job({
    required this.tid,
    required this.title,
    required this.body,
    required this.replyAuthor,
    required this.replyContent,
    required this.pid,
  });
}
