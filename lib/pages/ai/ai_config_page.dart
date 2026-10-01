import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/ai/ai_client.dart';
import '../../services/ai/ai_config.dart';
import '../../services/ai/ai_log.dart';
import '../../services/ai/auto_reply_engine.dart';
import '../../services/ai/auto_reply_scheduler.dart';
import '../../services/ai/forum_tools.dart';
import '../../services/api_service.dart';
import 'ai_log_page.dart';

/// AI 配置页：模型接入 + 生成参数 + 提示词 + 自动回复策略。
///
/// 全部参数写入 [AiConfig]，供后台自动回复引擎与 AI 助手读取。
class AiConfigPage extends StatefulWidget {
  const AiConfigPage({super.key});

  @override
  State<AiConfigPage> createState() => _AiConfigPageState();
}

class _AiConfigPageState extends State<AiConfigPage> {
  final _baseUrl = TextEditingController();
  final _apiKey = TextEditingController();
  final _model = TextEditingController();
  final _systemPrompt = TextEditingController();
  final _replyPrompt = TextEditingController();
  final _maxTokens = TextEditingController();
  final _timeout = TextEditingController();
  final _maxPerRun = TextEditingController();
  final _minLength = TextEditingController();
  final _interval = TextEditingController();
  final _unlockTemplate = TextEditingController();

  double _temperature = 0.7;
  bool _sendTemperature = true;
  bool _onlyOwn = true;
  bool _unlockMode = true;
  bool _unlockOnView = true;
  bool _dryRun = false;
  bool _autoReplyEnabled = false;
  bool _silentMode = true;

  List<String> _models = const [];
  String _modelStatus = '';
  String _testResult = '';
  bool _busyModels = false;
  bool _busyTest = false;
  bool _busyToolCheck = false;
  bool _runningOnce = false;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    _systemPrompt.dispose();
    _replyPrompt.dispose();
    _maxTokens.dispose();
    _timeout.dispose();
    _maxPerRun.dispose();
    _minLength.dispose();
    _interval.dispose();
    _unlockTemplate.dispose();
    super.dispose();
  }

  void _loadAll() {
    _baseUrl.text = AiConfig.baseUrl;
    _apiKey.text = AiConfig.apiKey;
    _model.text = AiConfig.model;
    _systemPrompt.text = AiConfig.systemPrompt;
    _replyPrompt.text = AiConfig.replyPrompt;
    _maxTokens.text = '${AiConfig.maxTokens}';
    _timeout.text = '${AiConfig.timeoutSeconds}';
    _maxPerRun.text = '${AiConfig.maxReplyPerRun}';
    _minLength.text = '${AiConfig.minReplyLength}';
    _interval.text = '${AiConfig.replyInterval}';
    _unlockTemplate.text = AiConfig.unlockReplyTemplate;
    _temperature = AiConfig.temperature;
    _sendTemperature = AiConfig.sendTemperature;
    _onlyOwn = AiConfig.onlyReplyOwnThreads;
    _unlockMode = AiConfig.unlockMode;
    _unlockOnView = AiConfig.unlockOnView;
    _dryRun = AiConfig.dryRun;
    _autoReplyEnabled = AiConfig.autoReplyEnabled;
    _silentMode = AiConfig.silentMode;
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 保存前先把「地址 + Key + 模型」落盘，因为 AiClient 直接读存储。
  Future<void> _persistConnection() async {
    await AiConfig.setBaseUrl(
      _baseUrl.text.trim().isEmpty ? AiConfig.defaultBaseUrl : _baseUrl.text,
    );
    await AiConfig.setApiKey(_apiKey.text);
    await AiConfig.setModel(_model.text);
    await AiConfig.setMaxTokens(_intOf(_maxTokens, 8192, 1, 128000));
    await AiConfig.setTimeoutSeconds(_intOf(_timeout, 60, 10, 600));
  }

  int _intOf(TextEditingController c, int def, int min, int max) {
    final v = int.tryParse(c.text.trim());
    if (v == null) return def;
    return v.clamp(min, max);
  }

  Future<void> _saveAll() async {
    final apiKey = _apiKey.text.trim();
    final model = _model.text.trim();
    final aiReady = apiKey.isNotEmpty && model.isNotEmpty;
    // 解锁隐藏贴发的是固定回复词，不经过 AI；只有「评论回复模式」依赖 AI 生成内容，
    // 因此缺凭证时不能连带把「隐藏贴回复词」一起拦下。
    if (!aiReady && !_unlockMode) {
      _toast('评论回复模式依赖 AI，请先填写 API Key 与模型名称');
      return;
    }

    await _persistConnection();
    await AiConfig.setSystemPrompt(_systemPrompt.text);
    await AiConfig.setReplyPrompt(_replyPrompt.text);
    await AiConfig.setTemperature(_temperature);
    await AiConfig.setMaxReplyPerRun(_intOf(_maxPerRun, 3, 1, 50));
    await AiConfig.setMinReplyLength(_intOf(_minLength, 8, 2, 200));
    await AiConfig.setReplyInterval(_intOf(_interval, 300, 30, 86400));
    await AiConfig.setOnlyReplyOwnThreads(_onlyOwn);
    await AiConfig.setUnlockMode(_unlockMode);
    await AiConfig.setUnlockOnView(_unlockOnView);
    await AiConfig.setUnlockReplyTemplate(_unlockTemplate.text);
    await AiConfig.setDryRun(_dryRun);
    await AiConfig.setSendTemperature(_sendTemperature);
    await AiConfig.setAutoReplyEnabled(_autoReplyEnabled);
    await AiConfig.setSilentMode(_silentMode);

    if (_autoReplyEnabled) {
      AutoReplyScheduler.start();
      AutoReplyScheduler.reschedule();
    } else {
      AutoReplyScheduler.stop();
    }

    _toast('已保存');
    if (mounted) Navigator.pop(context);
  }

  void _resetPrompts() {
    setState(() {
      _systemPrompt.text = AiConfig.defaultSystemPrompt;
      _replyPrompt.text = AiConfig.defaultReplyPrompt;
    });
    _toast('已恢复默认提示词，记得点保存');
  }

  Future<void> _fetchModels() async {
    if (_apiKey.text.trim().isEmpty) {
      _toast('请先填写 API Key');
      return;
    }
    setState(() {
      _busyModels = true;
      _modelStatus = '正在获取…';
    });
    await _persistConnection();
    final r = await AiClient.listModels();
    if (!mounted) return;
    setState(() {
      _busyModels = false;
      if (!r.success || r.models == null || r.models!.isEmpty) {
        _modelStatus = '获取失败：${r.error ?? '未知错误'}';
        _models = const [];
      } else {
        _models = r.models!;
        _modelStatus = '共 ${_models.length} 个可用模型，点击下方选择';
      }
    });
  }

  Future<void> _testConnection() async {
    if (_apiKey.text.trim().isEmpty) {
      _toast('请先填写 API Key');
      return;
    }
    setState(() {
      _busyTest = true;
      _testResult = '正在测试…';
    });
    await _persistConnection();
    final r = await AiClient.chat(
      [AiMsg.system('你是一个测试助手，只回一句话。'), AiMsg.user('回复：连接成功')],
      null,
    );
    if (!mounted) return;
    setState(() {
      _busyTest = false;
      _testResult = r.success
          ? '✅ 连接成功\n模型返回：${r.content}\n'
              'Token 用量：prompt=${r.promptTokens}, completion=${r.completionTokens}'
          : '❌ 连接失败\n${r.error}';
    });
  }

  /// 用一个必调工具的微型请求探测该模型/中转是否支持 function calling。
  Future<void> _checkToolCalling() async {
    if (_apiKey.text.trim().isEmpty) {
      _toast('请先填写 API Key');
      return;
    }
    setState(() {
      _busyToolCheck = true;
      _testResult = '正在探测…（会分别发一次带 tools 和不带 tools 的请求）';
    });
    await _persistConnection();

    const tools = [
      AiToolDef(
        'get_weather',
        '查询指定城市的天气。',
        '{"type":"object","properties":{'
            '"city":{"type":"string","description":"城市名"}},'
            '"required":["city"]}',
      ),
    ];
    final withTools = await AiClient.chat(
      [
        AiMsg.system('你必须使用提供的工具来回答，不要直接回答。'),
        AiMsg.user('北京今天天气怎么样？'),
      ],
      tools,
      maxTokensOverride: 1024,
    );
    final withoutTools = await AiClient.chat(
      [
        AiMsg.system('你可以调用 get_weather(city) 这个工具。'),
        AiMsg.user('北京今天天气怎么样？'),
      ],
      null,
    );
    if (!mounted) return;

    final called =
        withTools.success && (withTools.toolCalls?.isNotEmpty ?? false);
    final sb = StringBuffer();
    sb.writeln(called ? '✅ 支持工具调用（function calling）\n' : '❌ 不支持、或中转没转发 tools\n');
    sb.writeln('带 tools 请求：');
    if (!withTools.success) {
      sb.writeln('失败 → ${withTools.error}');
    } else {
      sb.writeln(
        'finish_reason=${withTools.finishReason.isEmpty ? '空' : withTools.finishReason}，'
        'tool_calls=${withTools.toolCalls?.length ?? 0}，'
        'content=${withTools.content.isEmpty ? '空' : '有'}',
      );
    }
    sb.writeln('\n不带 tools 请求：');
    if (!withoutTools.success) {
      sb.writeln('失败 → ${withoutTools.error}');
    } else {
      sb.writeln('content=${withoutTools.content.isEmpty ? '空' : '有'}');
    }
    sb.writeln();
    if (called) {
      sb.writeln('结论：这个模型可以直接用工具读论坛数据，走标准模式即可。');
    } else {
      sb.writeln(
        '结论：模型只会输出文字。应用已内置兼容层，会自动从文字里识别调用意图'
        '并代它执行，所以功能仍可用；若想更快更稳，建议换成 gpt-4o-mini / deepseek-chat。',
      );
    }
    if (withTools.success && withTools.content.isNotEmpty) {
      sb.writeln('\n模型带 tools 时的原话：\n${AiLog.clip(withTools.content, 300)}');
    } else if (withoutTools.success && withoutTools.content.isNotEmpty) {
      sb.writeln('\n模型原话：\n${AiLog.clip(withoutTools.content, 300)}');
    }

    setState(() {
      _busyToolCheck = false;
      _testResult = sb.toString();
    });
  }

  Future<void> _runAutoReplyOnce() async {
    if (_runningOnce) return;
    if (!ApiService.instance.isLoggedIn) {
      _toast('请先登录论坛账号');
      return;
    }
    if (!AiConfig.isConfigured) {
      _toast('请先填好接口地址、API Key 和模型');
      return;
    }
    setState(() => _runningOnce = true);
    await AutoReplyEngine.runOnce(
      callback: (replied, skipped, detail) {
        _toast('已回复 $replied 条，跳过 $skipped 条\n$detail');
      },
    );
    if (mounted) setState(() => _runningOnce = false);
  }

  void _applyQuickFill(String url, String model) {
    setState(() {
      _baseUrl.text = url;
      _model.text = model;
      _models = const [];
      _modelStatus = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 配置'),
        actions: [
          IconButton(
            tooltip: '运行日志',
            icon: const Icon(Icons.article_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AiLogPage()),
            ),
          ),
          TextButton(onPressed: _saveAll, child: const Text('保存')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          _section('模型接入'),
          TextField(
            controller: _baseUrl,
            decoration: const InputDecoration(
              labelText: '接口地址（Base URL）',
              hintText: 'https://api.openai.com/v1',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _apiKey,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'API Key'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _model,
            decoration: const InputDecoration(
              labelText: '模型名称',
              hintText: 'gpt-4o-mini / deepseek-chat',
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              ActionChip(
                label: const Text('OpenAI'),
                onPressed: () =>
                    _applyQuickFill('https://api.openai.com/v1', 'gpt-4o-mini'),
              ),
              ActionChip(
                label: const Text('DeepSeek'),
                onPressed: () => _applyQuickFill(
                  'https://api.deepseek.com/v1',
                  'deepseek-chat',
                ),
              ),
              ActionChip(
                label: const Text('通义千问'),
                onPressed: () => _applyQuickFill(
                  'https://dashscope.aliyuncs.com/compatible-mode/v1',
                  'qwen-plus',
                ),
              ),
              ActionChip(
                label: const Text('Kimi'),
                onPressed: () => _applyQuickFill(
                  'https://api.moonshot.cn/v1',
                  'moonshot-v1-8k',
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _busyModels ? null : _fetchModels,
                icon: _busyModels
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_outlined, size: 18),
                label: const Text('获取模型列表'),
              ),
            ],
          ),
          if (_modelStatus.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _modelStatus,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (_models.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: DropdownButtonFormField<String>(
                value: _models.contains(_model.text) ? _model.text : null,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '从列表选择模型'),
                items: [
                  for (final m in _models)
                    DropdownMenuItem(value: m, child: Text(m, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _model.text = v);
                },
              ),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _busyTest ? null : _testConnection,
                  child: const Text('测试连接'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: _busyToolCheck ? null : _checkToolCalling,
                  child: const Text('工具调用自检'),
                ),
              ),
            ],
          ),
          if (_testResult.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SelectableText(
                _testResult,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),

          _section('生成参数'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('温度 ${_temperature.toStringAsFixed(1)}'),
            subtitle: Slider(
              value: _temperature.clamp(0, 2),
              max: 2,
              divisions: 20,
              label: _temperature.toStringAsFixed(1),
              onChanged: (v) => setState(() => _temperature = v),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('请求时发送温度'),
            subtitle: const Text('部分模型 / 中转只接受 temperature=1，可关闭'),
            value: _sendTemperature,
            onChanged: (v) => setState(() => _sendTemperature = v),
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _maxTokens,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(labelText: 'max_tokens'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _timeout,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(labelText: '超时（秒）'),
                ),
              ),
            ],
          ),

          _section('提示词'),
          TextField(
            controller: _systemPrompt,
            minLines: 3,
            maxLines: 8,
            decoration: const InputDecoration(
              labelText: '系统提示词（AI 助手）',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _replyPrompt,
            minLines: 3,
            maxLines: 8,
            decoration: const InputDecoration(
              labelText: '自动回复提示词',
              alignLabelWithHint: true,
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _resetPrompts,
              child: const Text('恢复默认提示词'),
            ),
          ),

          _section('自动回复策略'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('启用后台自动回复'),
            value: _autoReplyEnabled,
            onChanged: (v) => setState(() => _autoReplyEnabled = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('静默模式'),
            subtitle: const Text('不弹通知，后台悄悄回复'),
            value: _silentMode,
            onChanged: (v) => setState(() => _silentMode = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('解锁隐藏内容模式'),
            subtitle: const Text('开：进帖自动回复解锁；关：回复自己帖子的新评论'),
            value: _unlockMode,
            onChanged: (v) => setState(() => _unlockMode = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('进帖自动解锁'),
            subtitle: const Text('打开含「回复可见」的帖子时自动回复并解锁'),
            value: _unlockOnView,
            onChanged: (v) => setState(() => _unlockOnView = v),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 2),
            child: TextField(
              controller: _unlockTemplate,
              minLines: 1,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: '隐藏贴回复词',
                hintText: '留空则使用内置模板',
                helperText: '自动回复隐藏贴时发送该内容；{title} 会替换为帖子标题关键词',
                helperMaxLines: 2,
                alignLabelWithHint: true,
                prefixIcon: Icon(Icons.keyboard_alt_outlined),
              ),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('只回复自己帖子的评论'),
            subtitle: const Text('更安全，避免在别人帖子里乱回复'),
            value: _onlyOwn,
            onChanged: (v) => setState(() => _onlyOwn = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('演练模式'),
            subtitle: const Text('只生成不发送，用于调试提示词'),
            value: _dryRun,
            onChanged: (v) => setState(() => _dryRun = v),
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _maxPerRun,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(labelText: '单轮最多回复'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _minLength,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(labelText: '最短回复字数'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _interval,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(labelText: '轮询间隔（秒）'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _runningOnce ? null : _runAutoReplyOnce,
            icon: _runningOnce
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow_rounded, size: 18),
            label: const Text('立即执行一轮自动回复'),
          ),

          _section('工具能力'),
          Text(
            '当前内置工具：${ForumTools.definitions().map((t) => t.name).join('、')}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 22, bottom: 10),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
      ),
    );
  }
}
