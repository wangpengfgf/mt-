import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 导出随包分发的软件源码压缩包。
///
/// 源码包以 asset 形式打进 APK（见 pubspec.yaml 的 assets/source/），
/// 这里把它释放到外部存储，供用户用文件管理器取出查看。
class SourceExportService {
  SourceExportService._();

  /// 资源清单不可用时的固定兜底路径。
  static const String _fallbackAsset =
      'assets/source/MTForum_source_v2.46.5.zip';

  /// 导出结果。
  static Future<SourceExportResult> export() async {
    try {
      final asset = await _locateAsset();
      final data = await rootBundle.load(asset);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );

      final dir = await _targetDir();
      if (!await dir.exists()) await dir.create(recursive: true);
      final file = File('${dir.path}/${asset.split('/').last}');
      await file.writeAsBytes(bytes, flush: true);

      return SourceExportResult(
        success: true,
        path: file.path,
        size: bytes.length,
        message: '已导出源码包',
      );
    } catch (e) {
      return SourceExportResult(
        success: false,
        path: '',
        size: 0,
        message: '导出失败：$e',
      );
    }
  }

  /// 在资源清单里找源码包，避免版本号变更后路径失效。
  static Future<String> _locateAsset() async {
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final candidates =
          manifest
              .listAssets()
              .where((k) => k.startsWith('assets/source/') && k.endsWith('.zip'))
              .toList()
            ..sort();
      if (candidates.isNotEmpty) return candidates.last;
    } catch (_) {
      // 清单读取失败时回退到固定路径。
    }
    return _fallbackAsset;
  }

  /// 优先外部存储（文件管理器可直接看到），不可用时退回应用文档目录。
  static Future<Directory> _targetDir() async {
    final external = await getExternalStorageDirectory();
    if (external != null) return external;
    return getApplicationDocumentsDirectory();
  }
}

/// 导出结果。
class SourceExportResult {
  final bool success;
  final String path;
  final int size;
  final String message;

  const SourceExportResult({
    required this.success,
    required this.path,
    required this.size,
    required this.message,
  });
}
