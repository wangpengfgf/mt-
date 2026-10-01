import 'dart:convert';

import 'package:html/parser.dart' as html_parser;

import '../../models/models.dart';
import '../api_service.dart';
import 'ai_client.dart';

/// 论坛接口的 AI 工具层。
///
/// 把论坛的读接口包装成可被大模型 function calling 调用的工具，
/// 让 AI 能主动查询、学习、总结帖子内容。
///
/// 所有方法都是异步的，需在异步上下文调用。
class ForumTools {
  ForumTools._();

  /// 未解锁隐藏内容的标志文案（论坛「回复可见」型）
  static const String hiddenGateText = '查看本帖隐藏内容请';

  // ==================== 工具定义 ====================

  /// 返回全部可供 AI 调用的工具定义
  static List<AiToolDef> definitions() {
    return const [
      AiToolDef(
        'search_forum',
        '在 MT 论坛搜索帖子。返回匹配的帖子列表，含标题、作者、版块、回复数、链接和摘要。'
            '适合查找某个技术话题的讨论，例如「脱壳」「smali 修改」「签名校验」。',
        '{"type":"object","properties":{'
            '"keyword":{"type":"string","description":"搜索关键词"},'
            '"page":{"type":"integer","description":"页码，从1开始，默认1"}'
            '},"required":["keyword"]}',
      ),
      AiToolDef(
        'list_threads',
        '列出某个版块下的帖子。不传 fid 时返回论坛最新帖子。',
        '{"type":"object","properties":{'
            '"fid":{"type":"string","description":"版块ID，例如 2。不传则取最新帖子"},'
            '"page":{"type":"integer","description":"页码，从1开始"}'
            '},"required":[]}',
      ),
      AiToolDef(
        'list_forums',
        '获取论坛的全部版块列表（含版块ID，供 list_threads 使用）。',
        '{"type":"object","properties":{},"required":[]}',
      ),
      AiToolDef(
        'get_thread',
        '获取帖子完整详情，包含楼主正文、隐藏内容、统计数据和回复列表。'
            '默认会把该帖的回复一次性抓到底（跨所有分页），无需手动翻页。'
            '这是学习帖子内容的主要接口，返回纯文本正文，便于阅读和总结。',
        '{"type":"object","properties":{'
            '"tid":{"type":"string","description":"帖子ID"},'
            '"page":{"type":"integer","description":"起始回复页码，从1开始"},'
            '"max_replies":{"type":"integer","description":"最多返回多少条回复，默认200"},'
            '"fetch_all":{"type":"boolean","description":"是否抓全所有分页的回复，默认 true"}'
            '},"required":["tid"]}',
      ),
      AiToolDef(
        'get_replies',
        '获取帖子的回复列表。默认自动翻页、一次抓到底（跨所有分页）。',
        '{"type":"object","properties":{'
            '"tid":{"type":"string","description":"帖子ID"},'
            '"page":{"type":"integer","description":"起始页码，从1开始"},'
            '"max_replies":{"type":"integer","description":"最多返回多少条，默认300"},'
            '"fetch_all":{"type":"boolean","description":"是否抓全所有分页，默认 true"}'
            '},"required":["tid"]}',
      ),
      AiToolDef(
        'my_threads',
        '获取当前登录用户的帖子列表。',
        '{"type":"object","properties":{'
            '"page":{"type":"integer","description":"页码，从1开始"}'
            '},"required":[]}',
      ),
      AiToolDef(
        'get_notices',
        '获取当前用户的通知和私信列表，含未读状态。',
        '{"type":"object","properties":{'
            '"type":{"type":"string","enum":["pm","notice","follower","system"],'
            '"description":"类型：pm 私信 / notice 通知 / follower 粉丝 / system 系统"}'
            '},"required":[]}',
      ),
      AiToolDef(
        'get_user_profile',
        '获取指定用户的资料（等级、积分、发帖数、签名等）。',
        '{"type":"object","properties":{'
            '"uid":{"type":"string","description":"用户ID"}'
            '},"required":["uid"]}',
      ),
      AiToolDef(
        'post_reply',
        '在指定帖子下发表一条回复。谨慎使用，只有确实需要时才发。',
        '{"type":"object","properties":{'
            '"tid":{"type":"string","description":"帖子ID"},'
            '"message":{"type":"string","description":"回复正文"}'
            '},"required":["tid","message"]}',
      ),
      AiToolDef(
        'unlock_hidden',
        '解锁帖子的隐藏内容：对含「回复可见」的帖子自动发一条贴合正文的回复，'
            '然后回读隐藏内容。若没有隐藏内容或已解锁则不做写操作。',
        '{"type":"object","properties":{'
            '"tid":{"type":"string","description":"帖子ID"},'
            '"message":{"type":"string","description":"可选，自定义回复内容"}'
            '},"required":["tid"]}',
      ),
    ];
  }

  /// 把工具清单渲染成纯文本说明，供不支持 function calling 的模型使用。
  static String textToolCatalog() {
    final sb = StringBuffer();
    sb.writeln('你可以调用下列工具读取 MT 论坛的真实数据。');
    sb.writeln('需要调用工具时，只输出一行 JSON，不要任何额外文字、不要 markdown 代码块：');
    sb.writeln('{"tool":"工具名","args":{参数}}');
    sb.writeln('要一次拿多个数据，就输出多行，每行一个调用。');
    sb.writeln('拿到工具结果后：还需要更多数据就继续输出调用行；');
    sb.writeln('信息已经够回答用户时，直接输出最终回答的正文，不要再输出任何 JSON。');
    sb.writeln('绝对不要只在脑子里计划要调用什么，要么真的输出调用行，要么直接回答。\n');
    sb.writeln('可用工具：');
    for (final t in definitions()) {
      sb.writeln('- ${t.name}：${t.description}');
      sb.writeln('  参数：${t.parametersJson}');
    }
    return sb.toString();
  }

  /// 执行一次工具调用，返回 JSON 字符串结果，供回填给模型。
  static Future<String> execute(
    String toolName,
    Map<String, dynamic> args,
  ) async {
    try {
      switch (toolName) {
        case 'search_forum':
          return await _searchForum(args);
        case 'list_threads':
          return await _listThreads(args);
        case 'list_forums':
          return await _listForums();
        case 'get_thread':
          return await _getThread(args);
        case 'get_replies':
          return await _getReplies(args);
        case 'my_threads':
          return await _myThreads(args);
        case 'get_notices':
          return await _getNotices(args);
        case 'get_user_profile':
          return await _getUserProfile(args);
        case 'post_reply':
          return await _postReply(args);
        case 'unlock_hidden':
          return await _unlockHidden(args);
        default:
          return _err('未知工具: $toolName');
      }
    } catch (e) {
      return _err('${e.runtimeType}: $e');
    }
  }

  // ==================== 读接口实现 ====================

  static Future<String> _searchForum(Map<String, dynamic> args) async {
    final kw = '${args['keyword'] ?? ''}'.trim();
    if (kw.isEmpty) return _err('关键词为空');
    final page = _asInt(args['page'], 1).clamp(1, 9999);
    if (!ApiService.instance.isLoggedIn) {
      return _err('搜索需要登录，请先在应用内登录 MT 论坛账号');
    }
    final list = await ApiService.instance.search(kw, page: page);
    return jsonEncode({
      'keyword': kw,
      'page': page,
      'count': list.length,
      'threads': [
        for (final t in list)
          {
            'tid': t.tid,
            'title': t.title ?? '',
            'author': t.authorName ?? '',
            'author_uid': t.authorUid ?? '',
            'forum_name': t.forumName ?? '',
            'publish_time': t.postTime ?? '',
            'replies': t.replyCount ?? '',
            'views': t.viewCount ?? '',
            'summary': _clip(t.excerpt ?? '', 400),
            'url': '${ApiService.baseUrl}/thread-${t.tid}-1-1.html',
          },
      ],
    });
  }

  static Future<String> _listThreads(Map<String, dynamic> args) async {
    final fid = '${args['fid'] ?? ''}'.trim();
    final page = _asInt(args['page'], 1).clamp(1, 9999);

    List<Thread> list;
    if (fid.isEmpty) {
      list = await ApiService.instance.getThreadList(page: page, view: 'newthread');
    } else {
      list = await ApiService.instance.getForumThreads(fid: fid, page: page);
    }
    return jsonEncode({
      'fid': fid,
      'page': page,
      'count': list.length,
      'threads': _threadsToJson(list),
    });
  }

  static Future<String> _listForums() async {
    final groups = await ApiService.instance.getForumGroups();
    return jsonEncode({
      'count': groups.length,
      'categories': [
        for (final g in groups)
          {
            'category': g.name,
            'forums': [
              for (final b in g.boards)
                {
                  'fid': b.fid,
                  'name': b.name,
                  'today_posts': b.todayPosts ?? 0,
                },
            ],
          },
      ],
    });
  }

  static Future<String> _getThread(Map<String, dynamic> args) async {
    final tid = '${args['tid'] ?? ''}'.trim();
    if (tid.isEmpty) return _err('tid 为空');
    final page = _asInt(args['page'], 1).clamp(1, 9999);
    var maxReplies = _asInt(args['max_replies'], 200);
    if (maxReplies <= 0) maxReplies = 200;
    final fetchAll = args['fetch_all'] == null
        ? true
        : args['fetch_all'] == true;

    final detail = await ApiService.instance.getThreadDetail(tid, page: page);

    final allReplies = <Post>[
      for (final p in detail.posts)
        if (!p.isOp) p,
    ];

    // 抓全回复：从当前页往后逐页拉取
    var truncated = false;
    if (fetchAll) {
      // Flutter 端未暴露总页数，按存在性逐页试探，设硬上限防死循环
      const maxPages = 60;
      var p = page + 1;
      while (p <= maxPages && allReplies.length < maxReplies) {
        try {
          final next = await ApiService.instance.getThreadDetail(tid, page: p);
          final newReplies = [
            for (final post in next.posts)
              if (!post.isOp) post,
          ];
          if (newReplies.isEmpty) break;
          allReplies.addAll(newReplies);
          p++;
        } catch (_) {
          break;
        }
      }
      if (allReplies.length >= maxReplies) truncated = true;
    }

    final op = detail.posts.isNotEmpty ? detail.posts.first : null;
    final body = op?.content ?? '';

    final out = <String, dynamic>{
      'tid': tid,
      'title': detail.title,
      'fid': detail.fid,
      'author': op?.authorName ?? '',
      'author_uid': op?.authorUid ?? '',
      'author_level': op?.authorLevel ?? '',
      'publish_time': op?.postTime ?? '',
      'reply_count': detail.replyCount ?? '',
      'like_count': detail.likeCount ?? '',
      'view_page': detail.page,
      'replies_fetched': allReplies.length,
      'replies_fetched_all': fetchAll && !truncated,
      'content': _clip(body, 12000),
      'content_length': body.length,
      'replies': _repliesToJson(allReplies, maxReplies),
    };
    if (op?.hiddenHint != null && op!.hiddenHint!.isNotEmpty) {
      out['hidden_hint'] = op.hiddenHint;
    }
    if (op != null && op.images.isNotEmpty) {
      out['images'] = op.images.take(12).toList();
    }
    return jsonEncode(out);
  }

  static Future<String> _getReplies(Map<String, dynamic> args) async {
    final tid = '${args['tid'] ?? ''}'.trim();
    if (tid.isEmpty) return _err('tid 为空');
    final page = _asInt(args['page'], 1).clamp(1, 9999);
    var max = _asInt(args['max_replies'], 300);
    if (max <= 0) max = 300;
    final fetchAll = args['fetch_all'] == null
        ? true
        : args['fetch_all'] == true;

    final detail = await ApiService.instance.getThreadDetail(tid, page: page);
    final all = <Post>[
      for (final p in detail.posts)
        if (!p.isOp) p,
    ];

    var truncated = false;
    if (fetchAll) {
      const maxPages = 60;
      var p = page + 1;
      while (p <= maxPages && all.length < max) {
        try {
          final next = await ApiService.instance.getThreadDetail(tid, page: p);
          final newReplies = [
            for (final post in next.posts)
              if (!post.isOp) post,
          ];
          if (newReplies.isEmpty) break;
          all.addAll(newReplies);
          p++;
        } catch (_) {
          break;
        }
      }
      if (all.length >= max) truncated = true;
    }

    final out = <String, dynamic>{
      'tid': tid,
      'start_page': page,
      'reply_count': detail.replyCount ?? '',
      'fetched': all.length,
      'fetched_all': fetchAll && !truncated,
      'replies': _repliesToJson(all, max),
    };
    if (truncated) out['note'] = '回复条数超过单次上限 $max，已截断';
    return jsonEncode(out);
  }

  static Future<String> _myThreads(Map<String, dynamic> args) async {
    if (!ApiService.instance.isLoggedIn) {
      return _err('当前未检测到登录态。请先在应用内登录 MT 论坛账号，再让 AI 读你的帖子。');
    }
    final page = _asInt(args['page'], 1).clamp(1, 9999);
    final list = await ApiService.instance.getMyThreads(page: page);
    final out = <String, dynamic>{
      'page': page,
      'uid': ApiService.instance.currentUid ?? '',
      'count': list.length,
      'threads': _threadsToJson(list),
    };
    if (list.isEmpty) {
      out['hint'] = '没有解析到帖子。可能该账号确实没有主题帖，或页面结构与解析规则不符。';
    }
    return jsonEncode(out);
  }

  static Future<String> _getNotices(Map<String, dynamic> args) async {
    if (!ApiService.instance.isLoggedIn) {
      return _err('需要登录后才能读取通知');
    }
    final type = '${args['type'] ?? 'notice'}';
    if (type == 'pm') {
      final convs = await ApiService.instance.getPmConversations();
      var unread = 0;
      final items = <Map<String, dynamic>>[];
      for (final c in convs) {
        if (c.hasUnread) unread++;
        items.add({
          'author': c.username,
          'author_uid': c.touid,
          'title': '',
          'summary': _clip(c.lastMessage ?? '', 300),
          'time': c.lastTime ?? '',
          'read': !c.hasUnread,
        });
      }
      return jsonEncode({
        'type': type,
        'unread': unread,
        'count': items.length,
        'items': items,
      });
    }

    final view = type == 'follower' || type == 'system' ? type : 'notice';
    final items = await ApiService.instance.getNotices(view: view);
    var unread = 0;
    final arr = <Map<String, dynamic>>[];
    for (final n in items) {
      if (n.isUnread) unread++;
      arr.add({
        'author': n.username,
        'author_uid': n.authorUid,
        'title': n.targetTitle ?? '',
        'summary': _clip(n.content, 300),
        'time': n.time,
        'read': !n.isUnread,
      });
    }
    return jsonEncode({
      'type': type,
      'unread': unread,
      'count': arr.length,
      'items': arr,
    });
  }

  static Future<String> _getUserProfile(Map<String, dynamic> args) async {
    final uid = '${args['uid'] ?? ''}'.trim();
    if (uid.isEmpty) return _err('uid 为空');
    final p = await ApiService.instance.getSpaceUserProfile(uid);
    return jsonEncode({
      'uid': uid,
      'username': p.username,
      'level': p.level ?? '',
      'group': p.userGroup ?? '',
      'signature': p.signature ?? '',
      'credits': p.credits ?? 0,
      'gold': p.gold ?? 0,
      'followers': p.followers ?? 0,
      'following': p.following ?? 0,
      'posts': p.posts ?? 0,
      'replies': p.replies ?? 0,
    });
  }

  // ==================== 写接口实现 ====================

  static Future<String> _postReply(Map<String, dynamic> args) async {
    final tid = '${args['tid'] ?? ''}'.trim();
    final message = '${args['message'] ?? ''}'.trim();
    if (tid.isEmpty) return _err('tid 为空');
    if (message.isEmpty) return _err('回复内容为空');
    if (!ApiService.instance.isLoggedIn) return _err('未登录，无法回复');

    final detail = await ApiService.instance.getThreadDetail(tid);
    final fid = detail.fid;
    if (fid.isEmpty) return _err('无法获取版块ID');

    final form = await ApiService.instance.getReplyPostForm(tid: tid, fid: fid);
    final result = await ApiService.instance.replyThread(
      tid: tid,
      fid: fid,
      noticeauthor: detail.noticeauthor,
      message: message,
      replyForm: form,
    );
    return jsonEncode({
      'success': result.success,
      'tid': tid,
      'message': message,
      if (!result.success) 'raw': _clip(result.message, 300),
    });
  }

  static Future<String> _unlockHidden(Map<String, dynamic> args) async {
    final tid = '${args['tid'] ?? ''}'.trim();
    if (tid.isEmpty) return _err('tid 为空');
    if (!ApiService.instance.isLoggedIn) return _err('未登录，无法解锁');
    var message = '${args['message'] ?? ''}'.trim();

    final detail = await ApiService.instance.getThreadDetail(tid);
    final op = detail.posts.isNotEmpty ? detail.posts.first : null;
    final out = <String, dynamic>{'tid': tid, 'title': detail.title};

    final hint = op?.hiddenHint ?? '';
    final hasHidden = hint.isNotEmpty || _containsGateWord(op?.content ?? '');
    if (!hasHidden) {
      out['success'] = true;
      out['hidden'] = false;
      out['note'] = '该帖子没有隐藏内容，无需解锁';
      return jsonEncode(out);
    }

    // 已解锁判断：正文或隐藏提示中不再含门控文案
    if (hint.isNotEmpty && !_containsGateWord(hint)) {
      out['success'] = true;
      out['hidden'] = true;
      out['already_unlocked'] = true;
      out['hint'] = hint;
      return jsonEncode(out);
    }

    if (message.isEmpty) {
      message = await _generateUnlockReply(detail.title, op?.content ?? '') ??
          '感谢分享，回复支持一下。';
    }
    message = _cleanupReply(message) ?? message;

    final fid = detail.fid;
    if (fid.isEmpty) return _err('无法获取版块ID');
    final form = await ApiService.instance.getReplyPostForm(tid: tid, fid: fid);
    final result = await ApiService.instance.replyThread(
      tid: tid,
      fid: fid,
      noticeauthor: detail.noticeauthor,
      message: message,
      replyForm: form,
    );

    out['success'] = result.success;
    out['hidden'] = true;
    out['message_sent'] = message;
    if (!result.success) {
      out['error'] = _clip(result.message, 200);
      return jsonEncode(out);
    }

    // 回读确认是否解锁
    try {
      final after = await ApiService.instance.getThreadDetail(tid);
      final newHint = after.posts.isNotEmpty ? (after.posts.first.hiddenHint ?? '') : '';
      final unlocked = newHint.isNotEmpty && !_containsGateWord(newHint);
      out['success'] = unlocked;
      if (unlocked) {
        out['hint'] = newHint;
      } else {
        out['note'] = '回复已提交，但回读时仍是未解锁状态。可能被论坛风控拦截，或隐藏内容需要审核后才可见。';
      }
    } catch (_) {
      out['note'] = '回复已提交，回读确认失败。';
    }
    return jsonEncode(out);
  }

  // ==================== 辅助 ====================

  static Future<String?> _generateUnlockReply(
    String title,
    String body,
  ) async {
    try {
      final p = StringBuffer();
      p.writeln('【帖子标题】$title\n');
      final text = htmlToText(body);
      p.writeln('【帖子正文】');
      p.writeln(text.length > 1500 ? text.substring(0, 1500) : text);
      p.writeln('\n该帖设置了回复可见。请写一条真诚、贴合帖子内容的回复，用来解锁隐藏内容。');
      const sys = '你是 MT 论坛的活跃成员。写一条自然、有信息量的回复，'
          '针对帖子内容本身，不要客套、不要用「楼主」开头，'
          '15 到 60 字，只输出回复正文，不要引号、不要 markdown。';
      final r = await AiClient.simpleChat(sys, p.toString());
      return _cleanupReply(r);
    } catch (_) {
      return null;
    }
  }

  static String? _cleanupReply(String? text) {
    if (text == null) return null;
    var t = text.trim();
    if (t.length > 1 &&
        ((t.startsWith('"') && t.endsWith('"')) ||
            (t.startsWith('「') && t.endsWith('」')) ||
            (t.startsWith('“') && t.endsWith('”')))) {
      t = t.substring(1, t.length - 1).trim();
    }
    t = t.replaceFirst(RegExp(r'^(回复|回答|评论)[:：]\s*'), '');
    t = t.replaceAll('**', '').trim();
    if (t.length > 200) t = t.substring(0, 200);
    return t;
  }

  static bool _containsGateWord(String html) {
    if (html.isEmpty) return false;
    final t = stripTags(html);
    return t.contains('如果您要查看') || t.contains('请回复') ||
        t.contains(hiddenGateText);
  }

  static List<Map<String, dynamic>> _threadsToJson(List<Thread> list) {
    return [
      for (final t in list)
        {
          'tid': t.tid,
          'title': t.title ?? '',
          'author': t.authorName ?? '',
          'author_uid': t.authorUid ?? '',
          'forum_name': t.forumName ?? '',
          'forum_fid': t.forumId ?? '',
          'publish_time': t.lastReplyTime ?? '',
          'replies': t.replyCount ?? '',
          'views': t.viewCount ?? '',
          'summary': _clip(t.excerpt ?? '', 400),
          'url': t.detailUrl,
        },
    ];
  }

  static List<Map<String, dynamic>> _repliesToJson(List<Post> list, int max) {
    final arr = <Map<String, dynamic>>[];
    var n = 0;
    var used = 0;
    const budget = 80000; // 总字符预算，防止抓全后撑爆模型上下文
    for (final r in list) {
      if (n >= max) break;
      var content = r.content;
      if (content.length > 1500) content = '${content.substring(0, 1500)}…';
      if (used + content.length > budget) break;
      used += content.length;
      arr.add({
        'pid': r.pid,
        'author': r.authorName ?? '',
        'author_uid': r.authorUid ?? '',
        'time': r.postTime ?? '',
        'content': content,
        'is_op': r.isOp,
      });
      n++;
    }
    return arr;
  }

  /// HTML 转纯文本，保留段落换行，去掉脚本样式
  static String htmlToText(String html) {
    if (html.isEmpty) return '';
    try {
      final doc = html_parser.parse(html);
      for (final e in doc.querySelectorAll('script,style')) {
        e.remove();
      }
      final text = doc.body?.text ?? doc.documentElement?.text ?? '';
      return text
          .replaceAll(RegExp(r'[ \t\x0B\f\r]+'), ' ')
          .replaceAll(RegExp(r'\n{3,}'), '\n\n')
          .trim();
    } catch (_) {
      return stripTags(html);
    }
  }

  static String stripTags(String html) {
    return html
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static int _asInt(dynamic v, int def) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? def;
    return def;
  }

  static String _clip(String s, int max) {
    if (s.isEmpty) return '';
    return s.length > max ? '${s.substring(0, max)}…[已截断]' : s;
  }

  static String _err(String msg) => jsonEncode({'error': msg});
}
