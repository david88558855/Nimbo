import 'json_store.dart';

/// 一个「还没传完的普通 PUT 上传」的断点信息。
///
/// WebDAV 没有标准的追加写，只能靠 `PUT` + `Content-Range` 这种非标准但被不少
/// 服务端（SabreDAV / Apache mod_dav / Nextcloud 等）实现的部分写入能力续传。
/// 续传起点以**远端临时文件的实测长度**为准，`offset` 只用于展示与排查。
///
/// 真正必须持久化的是 [length]：它把断点和「这个文件」绑在一起。没有它，同名但
/// 内容不同的文件会拿别人的前缀去拼，得到一个长度正确、内容错位的文件——比失败更糟。
class UploadCheckpoint {
  UploadCheckpoint({
    required this.length,
    this.mtimeMs = 0,
    this.offset = 0,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  /// 本地文件总字节数（判断断点是否属于同一个文件）。
  final int length;

  /// 本地文件修改时间（毫秒）。**长度相同但内容不同的文件**只能靠它区分：
  /// 少了这一项，同名同长度的另一个文件会拿别人的前缀拼出一个「完整但错位」的文件。
  /// 文件被 touch 过会失去续传资格——这是安全的失败方向（整份重传）。
  final int mtimeMs;

  /// 上次进度回调时的字节数，仅用于展示/排查；续传起点一律取实测。
  final int offset;

  final DateTime updatedAt;

  /// 断点是否属于当前这个文件（大小 + 修改时间都对得上）。
  bool matches(int size, int mtime) => length == size && mtimeMs == mtime;

  Map<String, dynamic> toJson() => {
        'length': length,
        'mtimeMs': mtimeMs,
        'offset': offset,
        'updatedAt': updatedAt.toIso8601String(),
      };

  static UploadCheckpoint? fromJson(Map<String, dynamic> j) {
    final length = (j['length'] as num?)?.toInt();
    if (length == null || length <= 0) return null;
    return UploadCheckpoint(
      length: length,
      mtimeMs: (j['mtimeMs'] as num?)?.toInt() ?? 0,
      offset: (j['offset'] as num?)?.toInt() ?? 0,
      updatedAt: DateTime.tryParse('${j['updatedAt']}'),
    );
  }
}

/// `userdata/uploads.json`：按 `mountId|remotePath` 存未完成上传的检查点。
///
/// 只服务「有临时文件 + 靠 Range 续写」这一类上传（当前是 WebDAV）。S3 分片另有
/// [MultipartStore]（要存 uploadId 与分片 ETag，信息量不同，不复用这张表）。
class UploadCheckpointStore {
  static const int maxAgeDays = 7;

  static final JsonStore _store = JsonStore('uploads.json');

  static String _key(String mountId, String path) => '$mountId|$path';

  /// 读取仍然适用的断点：总长度对不上说明换了文件，直接丢弃。
  static Future<UploadCheckpoint?> load(
    String mountId,
    String path,
    int length,
  ) =>
      _store.update<UploadCheckpoint?>((all) {
        final k = _key(mountId, path);
        final raw = all[k];
        if (raw is! Map) return null;
        final cp = UploadCheckpoint.fromJson(raw.cast<String, dynamic>());
        if (cp == null) {
          all.remove(k);
          return null;
        }
        final expired =
            DateTime.now().difference(cp.updatedAt).inDays > maxAgeDays;
        if (expired || cp.length != length) {
          all.remove(k);
          return null;
        }
        return cp;
      });

  static Future<void> save(String mountId, String path, UploadCheckpoint cp) async {
    try {
      await _store.update<void>((all) {
        all[_key(mountId, path)] = cp.toJson();
      });
    } catch (_) {}
  }

  static Future<void> remove(String mountId, String path) async {
    try {
      await _store.update<void>((all) {
        all.remove(_key(mountId, path));
      });
    } catch (_) {}
  }

  /// 删挂载时清掉该挂载的全部检查点。
  static Future<void> dropMount(String mountId) async {
    try {
      await _store.update<void>((all) {
        all.removeWhere((k, _) => k.startsWith('$mountId|'));
      });
    } catch (_) {}
  }
}
