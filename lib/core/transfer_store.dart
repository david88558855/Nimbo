import 'dart:convert';
import 'dart:io';

import 'models.dart';
import 'store.dart';

/// 传输记录的轻量持久化。
///
/// 只保留最近 60 条；重启后由 [TransferManager.restore] 恢复成「已暂停」，
/// 是否继续由用户决定 —— 自动重跑会在用户不知情时重新消耗流量。
class TransferStore {
  static const _maxKeep = 60;

  static Future<File> _file() async {
    final dir = await AppPaths.dataDir();
    return File('${dir.path}${Platform.pathSeparator}transfers.json');
  }

  static Future<void> save(List<TransferTask> all) async {
    try {
      final items = all.take(_maxKeep).map((t) => t.toJson()).toList();
      final f = await _file();
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode({'version': 1, 'tasks': items}));
      try {
        await tmp.rename(f.path);
      } on FileSystemException {
        await f.writeAsString(await tmp.readAsString());
        await tmp.delete();
      }
    } catch (_) {
      // 记录落盘失败不影响传输本身
    }
  }

  static Future<List<TransferTask>> load() async {
    try {
      final f = await _file();
      if (!f.existsSync()) return const [];
      final raw = jsonDecode(await f.readAsString());
      if (raw is! Map<String, dynamic>) return const [];
      final list = raw['tasks'];
      if (list is! List) return const [];
      return list
          .whereType<Map<String, dynamic>>()
          .map(TransferTask.fromJson)
          .where((t) =>
              t.id.isNotEmpty && t.mountId.isNotEmpty && t.localPath.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }
}
