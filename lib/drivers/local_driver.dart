import 'dart:io';
import 'dart:typed_data';

import '../core/format.dart';
import '../core/limiter.dart';
import '../core/models.dart';
import 'storage_driver.dart';

/// 本地与映射盘：SMB 场景由系统映射成盘符后从这里接入，应用不实现 SMB 协议。
class LocalDriver extends StorageDriver {
  LocalDriver(super.mount);

  @override
  String get scheme => 'file';

  // space 恒为 false：dart:io 没有取剩余空间的 API，需 FFI 调平台接口（见待办）。
  @override
  Capability get caps => const Capability(space: false, checksum: false, proxy: false);

  @override
  ResumeSupport get resume => ResumeSupport.both;

  @override
  Future<int> sizeOf(String path) async {
    final f = File(_fs(path));
    if (!f.existsSync()) return -1;
    try {
      return await f.length();
    } catch (_) {
      return -1;
    }
  }

  String get _root => mount.rootPath.isEmpty ? '/' : mount.rootPath;

  String _fs(String remotePath) {
    final p = normalizePath(remotePath);
    final base = _root.replaceAll(RegExp(r'[\\/]+$'), '');
    final rel = p == '/' ? '' : p.replaceAll('/', Platform.pathSeparator);
    return '$base$rel';
  }

  @override
  Future<void> connect() async {
    final dir = Directory(_root);
    if (!dir.existsSync()) {
      throw DriverException('本地目录不存在：$_root', kind: DriverErrorKind.notFound);
    }
  }

  @override
  Future<void> close() async {}

  @override
  Future<List<RemoteEntry>> list(String path) async {
    final dir = Directory(_fs(path));
    if (!dir.existsSync()) {
      throw DriverException('目录不存在：${_fs(path)}', kind: DriverErrorKind.notFound);
    }
    final result = <RemoteEntry>[];
    try {
      await for (final entity in dir.list(followLinks: false)) {
        final name = entity.path.split(Platform.pathSeparator).last;
        final isDir = entity is Directory;
        var size = 0;
        DateTime? modified;
        try {
          final stat = await entity.stat();
          size = stat.size;
          modified = stat.modified;
        } catch (_) {}
        result.add(RemoteEntry(
          name: name,
          path: joinPath(normalizePath(path), name),
          isDir: isDir,
          size: isDir ? 0 : size,
          modified: modified,
        ));
      }
    } on FileSystemException catch (e) {
      throw DriverException('读取目录失败：${e.message}', kind: DriverErrorKind.permission);
    }
    result.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return result;
  }

  @override
  Future<SpaceInfo?> space() async {
    // dart:io 无法直接取磁盘剩余空间，返回 null 由 UI 显示未知。
    return null;
  }

  @override
  Future<Uint8List> readAll(String path) async {
    final f = File(_fs(path));
    if (!f.existsSync()) throw DriverException('文件不存在：$path', kind: DriverErrorKind.notFound);
    return f.readAsBytes();
  }

  @override
  Future<void> downloadTo(String remotePath, String localFile,
      {ProgressFn? onProgress, int resumeFrom = 0}) async {
    final src = File(_fs(remotePath));
    if (!src.existsSync()) throw DriverException('文件不存在：$remotePath', kind: DriverErrorKind.notFound);
    final total = await src.length();
    final raf = await File(localFile).open(mode: FileMode.append);
    var done = resumeFrom;
    try {
      final existing = await raf.length();
      if (existing != done) {
        // 本地半截文件长度与记录不符：以实际长度为准，超出部分截掉。
        done = existing > total ? total : existing;
        await raf.truncate(done);
        await raf.setPosition(done);
      }
      await for (final chunk in src.openRead(done)) {
        await TransferLimiter.instance.download.take(chunk.length);
        await raf.writeFrom(chunk);
        done += chunk.length;
        onProgress?.call(done, total);
      }
    } finally {
      await raf.close();
    }
  }

  @override
  Future<void> uploadFile(String localFile, String remotePath,
      {ProgressFn? onProgress, int resumeFrom = 0}) async {
    final src = File(localFile);
    final total = await src.length();
    final dest = File(_fs(remotePath));
    await dest.parent.create(recursive: true);
    final raf = await dest.open(mode: FileMode.append);
    var done = resumeFrom;
    try {
      final existing = await raf.length();
      if (existing != done) {
        done = existing > total ? 0 : existing;
        await raf.truncate(done);
        await raf.setPosition(done);
      }
      await for (final chunk in src.openRead(done)) {
        await TransferLimiter.instance.upload.take(chunk.length);
        await raf.writeFrom(chunk);
        done += chunk.length;
        onProgress?.call(done, total);
      }
    } finally {
      await raf.close();
    }
  }

  @override
  Future<void> mkdir(String path) async {
    await Directory(_fs(path)).create(recursive: true);
  }

  @override
  Future<void> removeEntry(RemoteEntry entry) async {
    final p = _fs(entry.path);
    if (entry.isDir) {
      await Directory(p).delete(recursive: true);
    } else {
      await File(p).delete();
    }
  }

  @override
  @override
  Future<void> copyEntry(RemoteEntry from, String to) async {
    // 本地复制不必绕临时文件：直接让文件系统拷。
    final dst = _fs(to);
    final parent = Directory(File(dst).parent.path);
    if (!parent.existsSync()) await parent.create(recursive: true);
    await File(_fs(from.path)).copy(dst);
  }

  @override
  Future<void> move(String from, String to) async {
    final src = _fs(from);
    final dst = _fs(to);
    if (FileSystemEntity.isDirectorySync(src)) {
      await Directory(src).rename(dst);
    } else {
      await File(src).rename(dst);
    }
  }
}
