import 'dart:async';

import '../api_service.dart';
import 'ai_config.dart';
import 'ai_log.dart';
import 'auto_reply_engine.dart';

/// 自动回复调度器。
///
/// 职责：按用户配置的间隔周期性触发 [AutoReplyEngine]。
/// 应用启动时 [start]，用户关掉开关后引擎会自行空转返回。
class AutoReplyScheduler {
  AutoReplyScheduler._();

  static Timer? _timer;
  static bool _started = false;

  static bool get isStarted => _started;

  static void _scheduleNext() {
    _timer?.cancel();
    var interval = AiConfig.replyInterval;
    if (interval < 30) interval = 30;
    _timer = Timer(Duration(seconds: interval), _tick);
  }

  static void _tick() {
    unawaited(_tickOnce());
  }

  static Future<void> _tickOnce() async {
    try {
      if (!AiConfig.autoReplyEnabled) return;
      if (!AiConfig.isConfigured) {
        AiLog.e('scheduler', '自动回复已开启，但 AI 配置不完整，跳过');
        return;
      }
      if (!ApiService.instance.isLoggedIn) {
        AiLog.e('scheduler', '未登录，跳过本轮');
        return;
      }
      if (AutoReplyEngine.isRunning) return;

      await AutoReplyEngine.runOnce(
        callback: (replied, skipped, detail) {
          if (replied > 0 || skipped > 0) {
            AiLog.i(
              'scheduler',
              'replied=$replied skipped=$skipped $detail',
            );
          }
        },
      );
    } catch (e) {
      AiLog.e('scheduler', '调度异常：$e');
    } finally {
      _scheduleNext();
    }
  }

  /// 启动调度循环。重复调用无副作用。
  static void start() {
    if (_started) {
      _scheduleNext();
      return;
    }
    _started = true;
    AiLog.i('scheduler', '调度器已启动，间隔 ${AiConfig.replyInterval} 秒');
    // 启动阶段不要立刻打网络请求，延后一轮
    _scheduleNext();
  }

  static void stop() {
    _started = false;
    _timer?.cancel();
    _timer = null;
    AiLog.i('scheduler', '调度器已停止');
  }

  /// 开关或间隔变更后调用，让新配置立即生效
  static void reschedule() {
    if (_started) _scheduleNext();
  }
}
