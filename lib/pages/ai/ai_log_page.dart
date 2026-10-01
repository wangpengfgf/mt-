import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/ai/ai_log.dart';

/// 运行日志查看页。
///
/// AI 调用、自动回复、签到等结果都会写进 [AiLog]，静默失败时靠这里排查。
class AiLogPage extends StatefulWidget {
  const AiLogPage({super.key});

  @override
  State<AiLogPage> createState() => _AiLogPageState();
}

class _AiLogPageState extends State<AiLogPage> {
  @override
  Widget build(BuildContext context) {
    final text = AiLog.dump();
    return Scaffold(
      appBar: AppBar(
        title: const Text('运行日志'),
        actions: [
          IconButton(
            tooltip: '复制',
            icon: const Icon(Icons.copy_rounded),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已复制日志')),
              );
            },
          ),
          IconButton(
            tooltip: '清空',
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: () {
              AiLog.clear();
              setState(() {});
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SelectableText(
          text,
          style: const TextStyle(fontSize: 12, height: 1.5),
        ),
      ),
    );
  }
}
