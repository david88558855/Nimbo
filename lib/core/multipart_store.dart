import 'json_store.dart';

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

  /// 读写串行化与原子落盘都交给 [JsonStore]。
  static final JsonStore _store = JsonStore('multipart.json');

  static String _key(String mountId, String key) => '$mountId|$key';

  /// 读取仍然适用的状态：文件大小与分片大小都对不上就当作没有。
  static Future<MultipartState?> load(
    String mountId,
    String key,
    int length,
    int partSize,
  ) =>
      _store.update<MultipartState?>((all) {
        final k = _key(mountId, key);
        final raw = all[k];
        if (raw is! Map) return null;
        final state = MultipartState.fromJson(raw.cast<String, dynamic>());
        if (state == null) {
          all.remove(k);
          return null;
        }
        final expired =
            DateTime.now().difference(state.updatedAt).inDays > maxAgeDays;
        if (expired || state.length != length || state.partSize != partSize) {
          all.remove(k);
          return null;
        }
        return state;
      });

  /// 落盘失败不影响传输本身：状态只是「下次能快一点」的加速器。
  static Future<void> save(String mountId, String key, MultipartState state) async {
    try {
      await _store.update<void>((all) {
        all[_key(mountId, key)] = state.toJson();
      });
    } catch (_) {}
  }

  static Future<void> remove(String mountId, String key) async {
    try {
      await _store.update<void>((all) {
        all.remove(_key(mountId, key));
      });
    } catch (_) {}
  }

  /// 删挂载时清掉该挂载的全部状态：只删本地记录，服务端的未完成分片交给
  /// lifecycle 回收（主动 Abort 反而会让已传完的分片白费）。
  static Future<void> dropMount(String mountId) async {
    try {
      await _store.update<void>((all) {
        all.removeWhere((k, _) => k.startsWith('$mountId|'));
      });
    } catch (_) {}
  }
}
