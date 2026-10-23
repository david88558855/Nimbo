import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../drivers/factory.dart';
import '../drivers/storage_driver.dart';

/// 用户主动中止（暂停 / 取消）。
class TransferAborted implements Exception {
  const TransferAborted();
}

/// 传输队列。
///
/// 设计取舍：
/// - **每个任务一条独立连接**。FTP 的控制连接一次只能跑一个传输，
///   共用会话会让「同时上传 + 下载」互相阻塞；独立连接还让任务之间
///   互不影响，暂停一个不会打断另一个。
/// - **进度回调只改字段，UI 由定时器统一刷新**。一次 1 GB 的传输会
///   触发上千次回调，逐次 notifyListeners 会拖死列表。
/// - **中止在进度回调里抛出**。五个驱动的读写循环都会调 onProgress，
///   抛异常是最省改动、且对全部协议一致的中断点。
class TransferManager extends ChangeNotifier {
  TransferManager({this.maxConcurrent = 2});

  final List<TransferTask> tasks = [];
  int maxConcurrent;

  final Map<String, Mount> _mounts = {};
  Timer? _ticker;
  bool _disposed = false;
  int _seq = 0;

  int get runningCount =>
      tasks.where((t) => t.status == TransferStatus.running).length;

  int get queuedCount => tasks.where((t) => t.status == TransferStatus.queued).length;

  double get totalSpeed => tasks
      .where((t) => t.status == TransferStatus.running)
      .fold(0.0, (s, t) => s + t.speed);

  // ---------- 入队 ----------

  Future<void> enqueueDownload(Mount mount, RemoteEntry entry) async {
    if (entry.isDir) return;
    final dir = await downloadDir();
    final localPath = '${dir.path}${Platform.pathSeparator}${sanitizeName(entry.name)}';
    _mounts[mount.id] = mount;
    tasks.insert(
      0,
      TransferTask(
        id: _newId(),
        mountId: mount.id,
        mountName: mount.name,
        name: entry.name,
        remotePath: entry.path,
        localPath: localPath,
        dir: TransferDir.download,
        total: entry.size,
      ),
    );
    _pump();
  }

  Future<void> enqueueUpload(
    Mount mount,
    String localFile,
    String remoteDir, {
    String? name,
    String? remotePath,
  }) async {
    final f = File(localFile);
    if (!f.existsSync()) throw DriverException('本地文件不存在：$localFile');
    final fileName = name ?? f.uri.pathSegments.last;
    _mounts[mount.id] = mount;
    tasks.insert(
      0,
      TransferTask(
        id: _newId(),
        mountId: mount.id,
        mountName: mount.name,
        name: fileName,
        remotePath: remotePath ?? joinPath(remoteDir, fileName),
        localPath: localFile,
        dir: TransferDir.upload,
        total: await f.length(),
      ),
    );
    _pump();
  }

  /// 目录上传：递归遍历本地目录，每个文件一个任务，远端保留相对层级。
  ///
  /// 空目录不单独建任务（协议语义不一致），目录本身由任务的 mkdir 父目录
  /// 逻辑按需创建；返回入队文件数。
  Future<int> enqueueUploadDir(Mount mount, String localDir, String remoteDir) async {
    final root = Directory(localDir);
    if (!root.existsSync()) throw DriverException('本地目录不存在：$localDir');
    final files = <String>[];
    try {
      await for (final entity in root.list(recursive: true, followLinks: false)) {
        if (entity is File) files.add(entity.path);
      }
    } on FileSystemException catch (e) {
      throw DriverException('读取本地目录失败：${e.message}');
    }
    final base = root.path.replaceAll(RegExp(r'[\\/]+$'), '');
    final folderName = base.split(RegExp(r'[\\/]')).last;
    final target = joinPath(remoteDir, sanitizeName(folderName));
    for (final path in files) {
      final rel = path.substring(base.length).replaceAll('\\', '/').replaceAll(RegExp(r'^/+'), '');
      if (rel.isEmpty) continue;
      final segments = rel.split('/').map(sanitizeName).toList();
      await enqueueUpload(
        mount,
        path,
        target,
        name: segments.last,
        remotePath: '$target/${segments.join('/')}',
      );
    }
    return files.length;
  }

  // ---------- 控制 ----------

  /// 暂停 / 继续（同一个按钮）。
  void toggle(TransferTask task) {
    if (task.status == TransferStatus.running || task.status == TransferStatus.queued) {
      task.abort = task.status == TransferStatus.running;
      task.status = TransferStatus.paused;
      notifyListeners();
      return;
    }
    if (task.status == TransferStatus.paused || task.status == TransferStatus.failed) {
      resume(task);
    }
  }

  void resume(TransferTask task) {
    if (task.status == TransferStatus.running || task.status == TransferStatus.done) return;
    task.abort = false;
    task.transferred = 0;
    task.speed = 0;
    task.sampleAt = null;
    task.sampleBytes = 0;
    task.error = null;
    task.status = TransferStatus.queued;
    _pump();
  }

  void retry(TransferTask task) => resume(task);

  /// 取消：中止并移出列表。
  void cancel(TransferTask task) {
    task.abort = true;
    if (task.status == TransferStatus.running) {
      // 驱动退出前先从列表移除，_run 里的 contains 判断会跳过状态回写
      tasks.remove(task);
      notifyListeners();
      return;
    }
    tasks.remove(task);
    notifyListeners();
  }

  void clearFinished() {
    tasks.removeWhere((t) => t.status == TransferStatus.done);
    notifyListeners();
  }

  /// 挂载被删除时清掉相关任务。
  void dropMount(String mountId) {
    _mounts.remove(mountId);
    for (final t in tasks.where((x) => x.mountId == mountId && x.isActive)) {
      t.abort = true;
    }
    tasks.removeWhere((x) => x.mountId == mountId);
    notifyListeners();
  }

  // ---------- 队列推进 ----------

  void _pump() {
    if (_disposed) return;
    var running = runningCount;
    while (running < maxConcurrent) {
      TransferTask? next;
      for (final t in tasks) {
        if (t.status == TransferStatus.queued) {
          next = t;
          break;
        }
      }
      if (next == null) break;
      next.status = TransferStatus.running;
      next.error = null;
      next.abort = false;
      next.sampleAt = DateTime.now();
      next.sampleBytes = next.transferred;
      running++;
      unawaited(_run(next));
    }
    _ensureTicker();
    notifyListeners();
  }

  Future<void> _run(TransferTask task) async {
    final mount = _mounts[task.mountId];
    StorageDriver? driver;
    try {
      if (mount == null) throw DriverException('挂载已不存在，请重新添加后再试');
      driver = await createDriver(mount);
      await driver.connect();
      if (task.abort) throw const TransferAborted();

      if (task.dir == TransferDir.download) {
        await driver.downloadTo(
          task.remotePath,
          task.localPath,
          onProgress: (done, total) => _onProgress(task, done, total),
        );
      } else {
        final parent = parentPath(task.remotePath);
        if (parent != '/' && mount.protocol != MountProtocol.s3) {
          try {
            await driver.mkdir(parent);
          } catch (_) {
            // 目录已存在或无权限：让真正的写入去报错，避免掩盖真实原因
          }
        }
        await driver.uploadFile(
          task.localPath,
          task.remotePath,
          onProgress: (done, total) => _onProgress(task, done, total),
        );
      }
      if (task.abort) throw const TransferAborted();
      task.status = TransferStatus.done;
      task.transferred = task.total > 0 ? task.total : task.transferred;
      task.speed = 0;
      task.finishedAt = DateTime.now();
    } on TransferAborted {
      if (tasks.contains(task)) {
        task.status = TransferStatus.paused;
        task.speed = 0;
        if (task.dir == TransferDir.download) _discardPartial(task.localPath);
      }
    } catch (e) {
      if (tasks.contains(task)) {
        task.status = TransferStatus.failed;
        task.speed = 0;
        task.error = e is DriverException ? e.message : _short(e);
        if (task.dir == TransferDir.download) _discardPartial(task.localPath);
      }
    } finally {
      task.abort = false;
      try {
        await driver?.close();
      } catch (_) {}
      _pump();
    }
  }

  void _onProgress(TransferTask task, int done, int total) {
    task.transferred = done;
    if (total > 0) task.total = total;
    if (task.abort) throw const TransferAborted();
  }

  static String _short(Object e) {
    final s = '$e';
    return s.length > 220 ? '${s.substring(0, 220)}…' : s;
  }

  void _discardPartial(String localPath) {
    try {
      final f = File(localPath);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  // ---------- 速度采样 ----------

  void _ensureTicker() {
    if (_ticker != null || _disposed) return;
    _ticker = Timer.periodic(const Duration(milliseconds: 400), (_) {
      final now = DateTime.now();
      var busy = false;
      for (final t in tasks) {
        if (t.status != TransferStatus.running) {
          t.speed = 0;
          continue;
        }
        busy = true;
        final at = t.sampleAt;
        if (at == null) {
          t.sampleAt = now;
          t.sampleBytes = t.transferred;
          continue;
        }
        final ms = now.difference(at).inMilliseconds;
        if (ms < 200) continue;
        final delta = t.transferred - t.sampleBytes;
        final inst = delta <= 0 ? 0.0 : delta * 1000 / ms;
        t.speed = t.speed <= 0 ? inst : t.speed * 0.55 + inst * 0.45;
        t.sampleAt = now;
        t.sampleBytes = t.transferred;
      }
      if (busy) {
        notifyListeners();
      } else {
        _ticker?.cancel();
        _ticker = null;
        notifyListeners();
      }
    });
  }

  String _newId() => '${DateTime.now().microsecondsSinceEpoch}-${_seq++}';

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    _ticker = null;
    for (final t in tasks) {
      t.abort = true;
    }
    super.dispose();
  }
}

/// 下载目录：Windows 落在「下载/Nimbo」，Android 落在应用文档目录。
Future<Directory> downloadDir() async {
  if (Platform.isWindows) {
    final home = Platform.environment['USERPROFILE'];
    if (home != null && home.isNotEmpty) {
      final d = Directory('$home\\Downloads\\Nimbo');
      if (!d.existsSync()) d.createSync(recursive: true);
      return d;
    }
  }
  final base = await getApplicationDocumentsDirectory();
  final d = Directory('${base.path}${Platform.pathSeparator}Nimbo');
  if (!d.existsSync()) d.createSync(recursive: true);
  return d;
}

/// 本地落盘名：去掉 Windows 非法字符，避免下载失败才发现。
String sanitizeName(String name) {
  var s = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  if (s.isEmpty) s = 'unnamed';
  if (s.length > 180) s = s.substring(0, 180);
  return s;
}
