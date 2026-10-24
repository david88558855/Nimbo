import 'dart:convert';
import 'dart:io';

import 'store.dart';

/// 一次未完成的 S3 分片上传。
///
/// 只记「下次接着传需要的最小信息」：uploadId、文件大小与分片大小（用来判断
/// 状态是否还适用于当前文件）、已完成分片号与其 ETag（Complete 时必须原样回传）。
class MultipartState {
  MultipartState({
    required this.uploadId,
    required this.length,
    required this.partSize,
    required this.parts,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  final String uploadId;
  final int length;
  final int partSize;
  final Map<int, String> parts;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
        'uploadId': uploadId,
        'length': length,
        'partSize': partSize,
        'parts': parts.map((k, v) => MapEntry('$k', v)),
        'updatedAt': updatedAt.toIso8601String(),
      };

  static MultipartState? fromJson(Map<String, dynamic> j) {
    final uploadId = j['uploadId'];
    if (uploadId is! String || uploadId.isEmpty) return null;
    final rawParts = j['parts'];
    final parts = <int, String>{};
    if (rawParts is Map) {
      rawParts.forEach((k, v) {
        final n = int.tryParse('$k');
        if (n != null && v is String && v.isNotEmpty) parts[n] = v;
      });
    }
    return MultipartState(
      uploadId: uploadId,
      length: (j['length'] as num?)?.toInt() ?? 0,
      partSize: (j['partSize'] as num?)?.toInt() ?? 0,
      parts: parts,
      updatedAt: DateTime.tryParse('${j['updatedAt']}'),
    );
  }
}

/// `userdata/multipart.json`：按 `mountId|key` 存未完成的分片上传。
///
/// 为什么落盘：一次 1 GB 的上传要传 128 个分片，进程被杀（或用户先关掉应用）
/// 之后再进来，只有服务端的 uploadId 还不够——还得知道哪些分片已经传完，
/// 否则只能整份重传。ETag 必须持久化，Complete 时要原样回传。
///
/// 清理策略：超过 [maxAgeDays] 天的记录视为失效（S3 的 lifecycle 才真正回收
/// 未完成分片），不做 Abort —— 主动 Abort 会让已传完的分片白费。
class MultipartStore {
  static const int maxAgeDays = 7;

  /// 所有读写串行化：分片并发上传时会同时保存状态，交错写会互相覆盖。
  static Future<void> _chain = Future<void>.value();

  static Future<T> _serialize<T>(Future<T> Function() action) {
    final next = _chain.then((_) => action());
    _chain = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  static Future<File> _file() async {
    final dir = await AppPaths.dataDir();
    return File('${dir.path}${Platform.pathSeparator}multipart.json');
  }

  static String _key(String mountId, String key) => '$mountId|$key';

  static Future<Map<String, dynamic>> _readAll(File f) async {
    try {
      if (!f.existsSync()) return <String, dynamic>{};
      final raw = jsonDecode(await f.readAsString());
      if (raw is Map) return raw.cast<String, dynamic>();
      return <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  static Future<void> _writeAll(File f, Map<String, dynamic> all) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(all));
    try {
      await tmp.rename(f.path);
    } on FileSystemException {
      await f.writeAsString(await tmp.readAsString());
      await tmp.delete();
    }
  }

  /// 读取仍然适用的状态：文件大小与分片大小都对不上就当作没有。
  static Future<MultipartState?> load(
    String mountId,
    String key,
    int length,
    int partSize,
  ) =>
      _serialize(() async {
        final f = await _file();
        final all = await _readAll(f);
        final raw = all[_key(mountId, key)];
        if (raw is! Map) return null;
        final state = MultipartState.fromJson(raw.cast<String, dynamic>());
        if (state == null) return null;
        final expired =
            DateTime.now().difference(state.updatedAt).inDays > maxAgeDays;
        if (expired || state.length != length || state.partSize != partSize) {
          all.remove(_key(mountId, key));
          await _writeAll(f, all);
          return null;
        }
        return state;
      });

  static Future<void> save(String mountId, String key, MultipartState state) =>
      _serialize(() async {
        final f = await _file();
        final all = await _readAll(f);
        all[_key(mountId, key)] = state.toJson();
        await _writeAll(f, all);
      });

  static Future<void> remove(String mountId, String key) => _serialize(() async {
        final f = await _file();
        final all = await _readAll(f);
        if (all.remove(_key(mountId, key)) == null) return;
        await _writeAll(f, all);
      });
}
