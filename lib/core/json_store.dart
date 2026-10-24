import 'dart:convert';
import 'dart:io';

import 'store.dart';

/// 一个「小 JSON 状态文件」的读写原语。
///
/// 仓库里有两类中间状态要落盘（S3 未完成的分片上传、WebDAV 上传断点），形状完全一样：
/// `userdata/xxx.json` 里一张 `key → 对象` 的表，且读-改-写必须满足两件事：
///
/// 1. **串行化**——分片并发上传时多个协程会同时改同一张表，交错写会互相覆盖；
/// 2. **原子落盘**——先写 `.tmp` 再 rename，进程被杀不会留下半个 JSON。
///
/// 这两条都不该各写一遍，所以统一收在这里。
class JsonStore {
  JsonStore(this.fileName);

  /// 放在 [AppPaths.dataDir] 下的文件名，例如 `multipart.json`。
  final String fileName;

  Future<void> _chain = Future<void>.value();

  Future<File> _file() async {
    final dir = await AppPaths.dataDir();
    return File('${dir.path}${Platform.pathSeparator}$fileName');
  }

  /// 串行化的读-改-写：`change` 里可以增删键，返回值原样交给调用方。
  Future<T> update<T>(T Function(Map<String, dynamic> all) change) {
    final next = _chain.then((_) async {
      final f = await _file();
      final all = await _read(f);
      final result = change(all);
      await _write(f, all);
      return result;
    });
    // 链上不能留未捕获的异常，否则后面所有 update 都会挂着失败。
    _chain = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  static Future<Map<String, dynamic>> _read(File f) async {
    try {
      if (!f.existsSync()) return <String, dynamic>{};
      final raw = jsonDecode(await f.readAsString());
      if (raw is Map) return raw.cast<String, dynamic>();
      return <String, dynamic>{};
    } catch (_) {
      // 文件损坏按空处理：这些状态是「能续传」的加速器，丢了最多重新整份传。
      return <String, dynamic>{};
    }
  }

  static Future<void> _write(File f, Map<String, dynamic> all) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(all));
    try {
      await tmp.rename(f.path);
    } on FileSystemException {
      await f.writeAsString(await tmp.readAsString());
      await tmp.delete();
    }
  }
}
