import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

List<String> normalizeUpdateChangelog(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return const [];

  // 兼容服务端常见的几种公告格式：真实换行、JSON 中二次转义的
  // \\n/\\r\\n、HTML <br> / <p> / <li>，避免正文全部粘成一行。
  text = text
      .replaceAll(r'\r\n', '\n')
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\r', '\n')
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</(?:p|div|li)>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<li\b[^>]*>', caseSensitive: false), '• ')
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll(RegExp(r'[\t ]+[•●▪]\s*'), '\n• ')
      .replaceAllMapped(
        RegExp(r'([。；;])\s*(?=\d{1,2}[.、)])'),
        (match) => '${match.group(1)}\n',
      );

  final lines = text
      .split(RegExp(r'[\n\r]+'))
      .map((line) => line
          .replaceFirst(RegExp(r'^[•●▪*\-]+\s*'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim())
      .where((line) => line.isNotEmpty)
      .toList();

  // 某些 update.json 只有一整个中文段落且完全没有换行；长度较长时按
  // 句号/分号/问号/感叹号拆成易读条目。没有自然分隔符时保持原文。
  if (lines.length == 1 && lines.first.length > 48) {
    final sentenceLines = <String>[];
    final buffer = StringBuffer();
    for (final rune in lines.first.runes) {
      final char = String.fromCharCode(rune);
      buffer.write(char);
      if ('。！？；;'.contains(char)) {
        final value = buffer.toString().trim();
        if (value.isNotEmpty) sentenceLines.add(value);
        buffer.clear();
      }
    }
    final tail = buffer.toString().trim();
    if (tail.isNotEmpty) sentenceLines.add(tail);
    if (sentenceLines.length > 1) return sentenceLines;
  }

  return lines;
}

class UpdateInfo {
  final String version;
  final String changelog;
  final String downloadUrl;
  final int? size;

  const UpdateInfo({
    required this.version,
    required this.changelog,
    required this.downloadUrl,
    this.size,
  });

  /// 从 GitHub Release 接口响应构造。
  ///
  /// 版本号取 tag（去掉 v 前缀），更新说明取 body，安装包取附件里的 .apk。
  factory UpdateInfo.fromGitHubRelease(Map<String, dynamic> json) {
    Map<String, dynamic>? apk;
    final assets = json['assets'];
    if (assets is List) {
      for (final asset in assets) {
        if (asset is! Map) continue;
        final name = '${asset['name'] ?? ''}'.toLowerCase();
        if (!name.endsWith('.apk')) continue;
        apk = asset.map((key, value) => MapEntry(key.toString(), value));
        break;
      }
    }

    return UpdateInfo(
      version: _stripVersionPrefix('${json['tag_name'] ?? ''}'),
      changelog: '${json['body'] ?? ''}'.trim(),
      downloadUrl: '${apk?['browser_download_url'] ?? ''}'.trim(),
      size: int.tryParse('${apk?['size'] ?? ''}'),
    );
  }
}

/// 去掉 tag 常见的 v/V 前缀。
String _stripVersionPrefix(String tag) {
  final trimmed = tag.trim();
  if (trimmed.isEmpty) return '';
  final first = trimmed[0];
  if (first == 'v' || first == 'V') return trimmed.substring(1).trim();
  return trimmed;
}

/// 按点分数字段比较版本号，a 比 b 新时返回正数。
int compareVersions(String a, String b) {
  final left = _versionSegments(a);
  final right = _versionSegments(b);
  final length = left.length > right.length ? left.length : right.length;
  for (var i = 0; i < length; i++) {
    final x = i < left.length ? left[i] : 0;
    final y = i < right.length ? right[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

List<int> _versionSegments(String value) {
  return value
      .split(RegExp(r'[^0-9]+'))
      .where((segment) => segment.isNotEmpty)
      .map((segment) => int.tryParse(segment) ?? 0)
      .toList();
}

class UpdateCheckResult {
  final String currentVersion;
  final UpdateInfo info;

  const UpdateCheckResult({
    required this.currentVersion,
    required this.info,
  });

  /// Release 的版本号比本机新时提示更新。
  ///
  /// 版本号来自 Release tag，因此这里按版本名比较，而不是构建号。
  bool get hasUpdate => compareVersions(info.version, currentVersion) > 0;
}

class DownloadProgress {
  /// running / done / error，由原生层从 Gopeed 内核任务状态映射而来。
  final String state;
  final int downloaded;
  final int total;

  const DownloadProgress({
    required this.state,
    required this.downloaded,
    required this.total,
  });

  double? get fraction {
    if (total <= 0) return null;
    return downloaded / total;
  }

  bool get completed => state == 'done';
  bool get failed => state == 'error';
}

class UpdateService {
  UpdateService._();
  static final UpdateService instance = UpdateService._();

  static const _channel = MethodChannel('mtforum/update');
  static const _startupKey = 'startup_auto_check_update';

  /// 更新来源仓库（owner/repo）。
  ///
  /// 可在构建时用 --dart-define=MTFORUM_GITHUB_REPO=xxx/yyy 覆盖。
  static const String repo = String.fromEnvironment(
    'MTFORUM_GITHUB_REPO',
    defaultValue: 'wangpengfgf/mt-',
  );

  static const String _apiBase = 'https://api.github.com';

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      headers: const {
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'Cache-Control': 'no-cache',
        // GitHub API 强制要求 User-Agent，缺失会直接返回 403。
        'User-Agent': 'MTForum-Android',
      },
    ),
  );

  Future<bool> getStartupCheckEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_startupKey) ?? true;
  }

  Future<void> setStartupCheckEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_startupKey, value);
  }

  Future<Map<String, dynamic>> getCurrentVersionInfo() async {
    final raw = await _channel.invokeMapMethod<String, dynamic>('getVersionInfo');
    return raw ?? const <String, dynamic>{};
  }

  /// 读取 GitHub 上最新的 Release 作为更新来源。
  Future<UpdateCheckResult> check() async {
    if (repo.isEmpty) {
      throw StateError('更新仓库未配置，请通过 MTFORUM_GITHUB_REPO 构建');
    }

    final version = await getCurrentVersionInfo();
    final currentName = '${version['versionName'] ?? ''}';

    final response = await _dio.get<dynamic>(
      '$_apiBase/repos/$repo/releases/latest',
      queryParameters: {'_': DateTime.now().millisecondsSinceEpoch},
      options: Options(responseType: ResponseType.plain),
    );

    dynamic decoded = response.data;
    if (decoded is String) decoded = jsonDecode(decoded);
    if (decoded is! Map) {
      throw const FormatException('GitHub Release 响应格式错误');
    }

    final info = UpdateInfo.fromGitHubRelease(
      decoded.map((key, value) => MapEntry(key.toString(), value)),
    );

    if (info.version.isEmpty || info.downloadUrl.isEmpty) {
      throw const FormatException('最新 Release 缺少版本号或 APK 附件');
    }

    final downloadUri = Uri.tryParse(info.downloadUrl);
    if (downloadUri == null ||
        !const {'http', 'https'}.contains(downloadUri.scheme.toLowerCase()) ||
        downloadUri.host.isEmpty) {
      throw const FormatException('Release 附件的下载地址必须是 http/https');
    }

    return UpdateCheckResult(
      currentVersion: currentName,
      info: info,
    );
  }

  /// 交给原生层的 Gopeed 内核做多连接加速下载，返回内核任务 id。
  Future<String> startDownload(UpdateInfo info) async {
    final uri = Uri.tryParse(info.downloadUrl);
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
        uri.host.isEmpty) {
      throw StateError('软件更新下载地址无效，只支持 http/https');
    }
    final id = await _channel.invokeMethod<String>('startDownload', {
      'url': info.downloadUrl,
      'fileName': 'MTForum-${info.version}-Release.apk',
    });
    if (id == null || id.isEmpty) throw StateError('启动下载失败');
    return id;
  }

  Future<void> openDownloadInBrowser(UpdateInfo info) async {
    final uri = Uri.tryParse(info.downloadUrl);
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
        uri.host.isEmpty) {
      throw StateError('软件更新下载地址无效，只支持 http/https');
    }
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened) throw StateError('无法打开浏览器');
  }

  Future<DownloadProgress> queryDownload(String id) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'queryDownload',
      {'id': id},
    );
    if (result == null) {
      return const DownloadProgress(state: 'error', downloaded: 0, total: 0);
    }
    return DownloadProgress(
      state: '${result['state'] ?? 'running'}',
      downloaded: int.tryParse('${result['downloaded'] ?? 0}') ?? 0,
      total: int.tryParse('${result['total'] ?? 0}') ?? 0,
    );
  }

  Future<String> installDownload(String id) async {
    return await _channel.invokeMethod<String>('installDownload', {'id': id}) ??
        'failed';
  }
}

Future<void> showUpdateDialog(
  BuildContext context,
  UpdateCheckResult result,
) async {
  if (!result.hasUpdate) return;
  final info = result.info;
  final theme = Theme.of(context);
  final colors = theme.colorScheme;

  final lines = normalizeUpdateChangelog(info.changelog);

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 18, 10, 18),
              color: colors.primaryContainer.withValues(alpha: 0.72),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: colors.primary,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      Icons.rocket_launch_rounded,
                      color: colors.onPrimary,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '发现新版本',
                          style: theme.textTheme.titleLarge?.copyWith(
                            color: colors.onPrimaryContainer,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          'MTForum v${info.version}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colors.onPrimaryContainer
                                .withValues(alpha: 0.76),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '稍后更新',
                    onPressed: () => Navigator.pop(dialogContext),
                    icon: const Icon(Icons.close_rounded),
                    color: colors.onPrimaryContainer,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _UpdateVersionCard(
                          label: '当前版本',
                          version: result.currentVersion,
                          emphasized: false,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Icon(
                          Icons.arrow_forward_rounded,
                          color: colors.primary,
                        ),
                      ),
                      Expanded(
                        child: _UpdateVersionCard(
                          label: '最新版本',
                          version: info.version,
                          emphasized: true,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Icon(
                        Icons.auto_awesome_rounded,
                        size: 19,
                        color: colors.primary,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          '本次更新',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      if (info.size != null && info.size! > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: colors.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            _formatUpdateSize(info.size!),
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: colors.onSurfaceVariant,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 230),
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
                    decoration: BoxDecoration(
                      color: colors.surfaceContainer,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: colors.outlineVariant.withValues(alpha: 0.72),
                      ),
                    ),
                    child: SingleChildScrollView(
                      child: lines.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: Text(
                                '优化使用体验并修复已知问题',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            )
                          : Column(
                              children: [
                                for (var index = 0;
                                    index < lines.length;
                                    index++)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 10),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Container(
                                          width: 22,
                                          height: 22,
                                          alignment: Alignment.center,
                                          decoration: BoxDecoration(
                                            color: colors.primaryContainer,
                                            borderRadius:
                                                BorderRadius.circular(7),
                                          ),
                                          child: Text(
                                            '${index + 1}',
                                            style: theme.textTheme.labelSmall
                                                ?.copyWith(
                                              color:
                                                  colors.onPrimaryContainer,
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            lines[index],
                                            style: theme.textTheme.bodyMedium
                                                ?.copyWith(height: 1.5),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
              color: colors.surfaceContainerLow,
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        Navigator.pop(dialogContext);
                        try {
                          await UpdateService.instance
                              .openDownloadInBrowser(info);
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('打开浏览器失败：$e')),
                            );
                          }
                        }
                      },
                      icon: const Icon(
                        Icons.open_in_browser_rounded,
                        size: 18,
                      ),
                      label: const Text('浏览器下载'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () {
                        Navigator.pop(dialogContext);
                        showUpdateDownloadDialog(context, info);
                      },
                      icon: const Icon(Icons.download_rounded, size: 18),
                      label: const Text('立即更新'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

String _formatUpdateSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kilobytes = bytes / 1024;
  if (kilobytes < 1024) return '${kilobytes.toStringAsFixed(1)} KB';
  final megabytes = kilobytes / 1024;
  return '${megabytes.toStringAsFixed(1)} MB';
}

class _UpdateVersionCard extends StatelessWidget {
  final String label;
  final String version;
  final bool emphasized;

  const _UpdateVersionCard({
    required this.label,
    required this.version,
    required this.emphasized,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: emphasized
            ? colors.primaryContainer.withValues(alpha: 0.72)
            : colors.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: emphasized
              ? colors.primary.withValues(alpha: 0.28)
              : colors.outlineVariant.withValues(alpha: 0.68),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            'v$version',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              color: emphasized ? colors.primary : colors.onSurface,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> showUpdateDownloadDialog(
  BuildContext context,
  UpdateInfo info,
) async {
  final service = UpdateService.instance;
  String? downloadId;
  Timer? timer;
  final progress = ValueNotifier<DownloadProgress?>(null);
  final error = ValueNotifier<String?>(null);

  try {
    downloadId = await service.startDownload(info);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('下载失败：$e')),
      );
    }
    progress.dispose();
    error.dispose();
    return;
  }

  timer = Timer.periodic(const Duration(milliseconds: 650), (_) async {
    try {
      final value = await service.queryDownload(downloadId!);
      progress.value = value;
      if (value.completed || value.failed) timer?.cancel();
      if (value.failed) error.value = '安装包下载失败';
    } catch (e) {
      timer?.cancel();
      error.value = '$e';
    }
  });

  if (!context.mounted) {
    timer?.cancel();
    progress.dispose();
    error.dispose();
    return;
  }

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return AlertDialog(
        title: Text('正在下载 v${info.version}'),
        content: ValueListenableBuilder<DownloadProgress?>(
          valueListenable: progress,
          builder: (_, value, __) {
            return ValueListenableBuilder<String?>(
              valueListenable: error,
              builder: (_, errorText, __) {
                if (errorText != null) return Text(errorText);
                if (value == null) {
                  return const LinearProgressIndicator();
                }
                if (value.completed) {
                  return const Text('下载完成，可以安装新版本。');
                }
                final percent = value.fraction == null
                    ? null
                    : '${(value.fraction! * 100).clamp(0, 100).toStringAsFixed(0)}%';
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LinearProgressIndicator(value: value.fraction),
                    const SizedBox(height: 10),
                    Text(percent == null ? '下载中…' : '下载中 $percent'),
                  ],
                );
              },
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () {
              timer?.cancel();
              Navigator.pop(dialogContext);
            },
            child: const Text('后台下载'),
          ),
          ValueListenableBuilder<DownloadProgress?>(
            valueListenable: progress,
            builder: (_, value, __) {
              return FilledButton(
                onPressed: value?.completed == true
                    ? () async {
                        final result = await service.installDownload(downloadId!);
                        if (result == 'permission') {
                          if (dialogContext.mounted) {
                            ScaffoldMessenger.of(dialogContext).showSnackBar(
                              const SnackBar(
                                content: Text('请允许“安装未知应用”，返回后再次点击安装'),
                              ),
                            );
                          }
                        } else if (result == 'started' && dialogContext.mounted) {
                          Navigator.pop(dialogContext);
                        }
                      }
                    : null,
                child: const Text('安装'),
              );
            },
          ),
        ],
      );
    },
  );

  timer?.cancel();
  progress.dispose();
  error.dispose();
}
