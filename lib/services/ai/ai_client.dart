import 'dart:convert';

import 'package:dio/dio.dart';

import 'ai_config.dart';
import 'ai_log.dart';

/// 对话消息。
class AiMsg {
  String role; // system / user / assistant / tool
  String content;
  String? toolCallId; // role=tool 时对应哪次调用
  String? toolName;
  /// assistant 发起工具调用时的原始 tool_calls JSON 数组字符串
  String? toolCallsJson;
  /// 兼容层内部轮次的消息（工具结果回灌、计划文本、重申协议提示）。
  /// 标记后：不进主 history、不渲染气泡、不落盘。
  bool internal;

  AiMsg(this.role, this.content, {this.internal = false});

  AiMsg.system(String s) : this('system', s);

  AiMsg.user(String s) : this('user', s);

  AiMsg.assistant(String s) : this('assistant', s);

  factory AiMsg.tool(String callId, String? name, String result) {
    final m = AiMsg('tool', result);
    m.toolCallId = callId;
    m.toolName = name;
    return m;
  }

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        if (toolCallId != null && toolCallId!.isNotEmpty)
          'toolCallId': toolCallId,
        if (toolName != null && toolName!.isNotEmpty) 'toolName': toolName,
        if (toolCallsJson != null && toolCallsJson!.isNotEmpty)
          'toolCallsJson': toolCallsJson,
      };

  static AiMsg fromJson(Map<String, dynamic> o) {
    final m = AiMsg(
      '${o['role'] ?? ''}',
      '${o['content'] ?? ''}',
    );
    final tcId = o['toolCallId'];
    final tn = o['toolName'];
    final tcj = o['toolCallsJson'];
    m.toolCallId = (tcId is String && tcId.isNotEmpty) ? tcId : null;
    m.toolName = (tn is String && tn.isNotEmpty) ? tn : null;
    m.toolCallsJson = (tcj is String && tcj.isNotEmpty) ? tcj : null;
    return m;
  }
}

/// 工具定义
class AiToolDef {
  final String name;
  final String description;
  /// JSON Schema 字符串
  final String parametersJson;

  const AiToolDef(this.name, this.description, this.parametersJson);
}

/// 单次补全结果
class AiResult {
  bool success = false;
  String? error;
  String content = '';
  List<dynamic>? toolCalls;
  String finishReason = '';
  String reasoningContent = '';
  int promptTokens = 0;
  int completionTokens = 0;
  List<String>? models;
}

/// OpenAI 兼容协议客户端。
/// 支持 /chat/completions 的普通对话与 function calling（工具调用）。
class AiClient {
  AiClient._();

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      validateStatus: (_) => true,
      headers: const {'Accept': 'application/json'},
    ),
  );

  static Dio _buildClient() => _dio;

  static Future<AiResult> chat(
    List<AiMsg> messages,
    List<AiToolDef>? tools, {
    int maxTokensOverride = -1,
  }) async {
    final r = AiResult();
    final base = AiConfig.baseUrl;
    final key = AiConfig.apiKey;
    final model = AiConfig.model;

    if (key.isEmpty) {
      r.error = '未配置 API Key';
      return r;
    }
    if (model.isEmpty) {
      r.error = '未配置模型名称';
      return r;
    }

    final url = normalizeEndpoint(base);
    try {
      final body = <String, dynamic>{'model': model};

      final arr = <Map<String, dynamic>>[];
      for (final m in messages) {
        final o = <String, dynamic>{'role': m.role};
        if (m.role == 'tool') {
          o['tool_call_id'] = m.toolCallId ?? '';
          o['content'] = m.content;
          if (m.toolName != null && m.toolName!.isNotEmpty) {
            o['name'] = m.toolName;
          }
        } else if (m.role == 'assistant' &&
            m.toolCallsJson != null &&
            m.toolCallsJson!.isNotEmpty) {
          o['content'] = m.content.isEmpty ? null : m.content;
          o['tool_calls'] = jsonDecode(m.toolCallsJson!);
        } else {
          o['content'] = m.content;
        }
        arr.add(o);
      }
      body['messages'] = arr;

      if (tools != null && tools.isNotEmpty) {
        final toolArr = <Map<String, dynamic>>[];
        for (final t in tools) {
          final fn = <String, dynamic>{
            'name': t.name,
            'description': t.description,
            'parameters': t.parametersJson.isNotEmpty
                ? jsonDecode(t.parametersJson)
                : {'type': 'object', 'properties': <String, dynamic>{}},
          };
          toolArr.add({'type': 'function', 'function': fn});
        }
        body['tools'] = toolArr;
        body['tool_choice'] = 'auto';
      }

      body['temperature'] = AiConfig.temperature;
      final maxTokens =
          maxTokensOverride > 0 ? maxTokensOverride : AiConfig.maxTokens;
      body['max_tokens'] = maxTokens;
      // 显式声明非流式，避免部分中转默认走 SSE 导致这里解析到空
      body['stream'] = false;

      final sendTemperature = AiConfig.sendTemperature;
      if (!sendTemperature) {
        body.remove('temperature');
      }

      final requestBody0 = jsonEncode(body);
      AiLog.i(
        'ai-req',
        'POST $url\nmodel=$model max_tokens=$maxTokens '
            'temperature=${sendTemperature ? AiConfig.temperature.toStringAsFixed(2) : '不发送'} '
            'tools=${tools?.length ?? 0} messages=${messages.length} '
            'bodyBytes=${utf8.encode(requestBody0).length}\n'
            'body=${AiLog.clip(requestBody0, 1200)}',
      );

      final client = _buildClient();
      final timeout = Duration(seconds: AiConfig.timeoutSeconds);
      var response = await client.post<String>(
        url,
        data: requestBody0,
        options: Options(
          headers: {
            'Authorization': 'Bearer $key',
            'Content-Type': 'application/json',
          },
          responseType: ResponseType.plain,
          sendTimeout: timeout,
          receiveTimeout: timeout < const Duration(seconds: 30)
              ? const Duration(seconds: 30)
              : timeout,
        ),
      );
      var resp = response.data ?? '';
      var code = response.statusCode ?? 0;

      // 温度被拒：去掉 temperature 原样重试，并记住该选择
      if ((code < 200 || code >= 300) && _looksLikeTemperatureError(resp)) {
        AiLog.i('ai-req', 'temperature 被服务端拒绝，去掉后重试，并记住该选择');
        body.remove('temperature');
        await AiConfig.setSendTemperature(false);
        final requestBody1 = jsonEncode(body);
        response = await client.post<String>(
          url,
          data: requestBody1,
          options: Options(
            headers: {
              'Authorization': 'Bearer $key',
              'Content-Type': 'application/json',
            },
            responseType: ResponseType.plain,
            sendTimeout: timeout,
          ),
        );
        resp = response.data ?? '';
        code = response.statusCode ?? 0;
      }

      AiLog.i(
        'ai-resp',
        'HTTP $code bytes=${resp.length}\n${AiLog.clip(resp, 1500)}',
      );
      if (code < 200 || code >= 300) {
        r.error = 'HTTP $code ${_brief(resp)}';
        return r;
      }
      return _parseResponse(resp);
    } catch (e) {
      r.error = '${e.runtimeType}: $e';
      return r;
    }
  }

  static bool _looksLikeTemperatureError(String resp) {
    if (resp.isEmpty) return false;
    return resp.toLowerCase().contains('temperature');
  }

  static AiResult _parseResponse(String resp) {
    final r = AiResult();
    try {
      final json = jsonDecode(resp) as Map<String, dynamic>;
      if (json.containsKey('error')) {
        final err = json['error'];
        r.error = err is Map ? '${err['message'] ?? resp}' : '$resp';
        return r;
      }
      final usage = json['usage'];
      if (usage is Map) {
        r.promptTokens = (usage['prompt_tokens'] as num?)?.toInt() ?? 0;
        r.completionTokens = (usage['completion_tokens'] as num?)?.toInt() ?? 0;
      }
      final choices = json['choices'];
      if (choices is! List || choices.isEmpty) {
        r.error = '返回内容为空: ${_brief(resp)}';
        return r;
      }
      final choice = choices.first as Map<String, dynamic>;
      r.finishReason = '${choice['finish_reason'] ?? ''}';
      final msg = choice['message'];
      if (msg is Map<String, dynamic>) {
        r.content = msg['content'] == null ? '' : '${msg['content']}';
        // 推理型模型把思考写在 reasoning_content，正式回答在 content
        r.reasoningContent = '${msg['reasoning_content'] ?? ''}';
        if (r.content.isEmpty && r.reasoningContent.isNotEmpty) {
          r.content = r.reasoningContent;
        }
        final tc = msg['tool_calls'];
        if (tc is List && tc.isNotEmpty) r.toolCalls = tc;
      }
      r.success = true;
      return r;
    } catch (e) {
      r.error = '解析失败: $e';
      return r;
    }
  }

  /// 把 base URL 拼成完整的 chat/completions 端点
  static String normalizeEndpoint(String? base) {
    var b = (base ?? '').trim();
    if (b.isEmpty) b = AiConfig.defaultBaseUrl;
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    if (b.endsWith('/chat/completions')) return b;
    return '$b/chat/completions';
  }

  /// 拼出模型列表端点 /models
  static String normalizeModelsEndpoint(String? base) {
    var b = (base ?? '').trim();
    if (b.isEmpty) b = AiConfig.defaultBaseUrl;
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    if (b.endsWith('/chat/completions')) {
      b = b.substring(0, b.length - '/chat/completions'.length);
    }
    return '$b/models';
  }

  /// 拉取服务端可用模型列表（OpenAI 兼容的 GET /models）。
  static Future<AiResult> listModels() async {
    final r = AiResult();
    final key = AiConfig.apiKey;
    if (key.isEmpty) {
      r.error = '未配置 API Key';
      return r;
    }
    final url = normalizeModelsEndpoint(AiConfig.baseUrl);
    try {
      final client = _buildClient();
      final timeout = Duration(seconds: AiConfig.timeoutSeconds);
      final response = await client.get<String>(
        url,
        options: Options(
          headers: {
            'Authorization': 'Bearer $key',
            'Accept': 'application/json',
          },
          responseType: ResponseType.plain,
          sendTimeout: timeout,
          receiveTimeout: timeout,
        ),
      );
      final resp = response.data ?? '';
      final code = response.statusCode ?? 0;
      if (code < 200 || code >= 300) {
        r.error = 'HTTP $code ${_brief(resp)}';
        return r;
      }
      return _parseModelList(resp);
    } catch (e) {
      r.error = '${e.runtimeType}: $e';
      return r;
    }
  }

  static AiResult _parseModelList(String resp) {
    final r = AiResult();
    try {
      final json = jsonDecode(resp) as Map<String, dynamic>;
      if (json.containsKey('error')) {
        final err = json['error'];
        r.error = err is Map ? '${err['message'] ?? resp}' : '$resp';
        return r;
      }
      final ids = <String>[];
      var data = json['data'];
      data ??= json['models'];
      if (data is List) {
        for (final item in data) {
          if (item is Map) {
            var id = '${item['id'] ?? ''}';
            if (id.isEmpty) id = '${item['name'] ?? ''}';
            if (id.isNotEmpty) ids.add(id);
          } else if (item is String && item.isNotEmpty) {
            ids.add(item);
          }
        }
      }
      if (ids.isEmpty) {
        r.error = '接口未返回模型列表: ${_brief(resp)}';
        return r;
      }
      ids.sort();
      r.models = ids;
      r.success = true;
      return r;
    } catch (e) {
      r.error = '解析失败: $e';
      return r;
    }
  }

  /// 阻塞式单轮对话（不带工具），供自动回复等场景使用
  static Future<String?> simpleChat(
    String systemPrompt,
    String userPrompt,
  ) async {
    final msgs = <AiMsg>[];
    if (systemPrompt.isNotEmpty) msgs.add(AiMsg.system(systemPrompt));
    msgs.add(AiMsg.user(userPrompt));
    final r = await chat(msgs, null);
    if (!r.success) return null;
    return r.content;
  }

  static String _brief(String s) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length > 220 ? '${t.substring(0, 220)}...' : t;
  }
}
