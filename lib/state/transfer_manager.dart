import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../core/transfer_store.dart';
import '../drivers/errors.dart';
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
  TransferManager({this.maxConcurrent = 3});

  final List<TransferTask> tasks = [];
  int maxConcurrent;

  /// 下载落盘根目录（来自设置；空 = 用默认目录）。
  ///
  /// 只影响**新入队**的任务：已经在队列里的任务保留当初算好的 localPath，
  /// 否则改个设置会让跑了一半的任务写到另一个文件里。
  String downloadRoot = '';

  final Map<String, Mount> _mounts = {};
  Timer? _ticker;
  Timer? _saveTimer;
  bool _disposed = false;
  int _seq = 0;

  /// 恢复上次会话的任务列表：进行中的一律转成「已暂停」，绝不自动重跑。
  ///
  /// 必须把挂载一并登记进 `_mounts`：任务恢复后只剩 mountId，用户点「继续」时
  /// [_run] 要靠它重建连接。只传 id 集合的话，恢复出来的任务会一律报
  /// 「挂载已不存在」。
  Future<void> restore(List<TransferTask> saved, List<Mount> mounts) async {
    final byId = {for (final m in mounts) m.id: m};
    final usable = saved.where((t) => byId.containsKey(t.mountId)).toList();
    if (usable.isEmpty) return;
    _mounts
      ..clear()
      ..addAll(byId);
    tasks
      ..clear()
      ..addAll(usable);
    for (final t in tasks) {
      if (t.isActive) t.status = TransferStatus.paused;
      t.speed = 0;
      t.abort = false;
      if (t.resumeOffset <= 0) t.resumeOffset = t.transferred;
    }
    _seq = tasks.length;
    notifyListeners();
  }

  /// 立即落盘（退出前调用）：取消防抖，避免 `exit(0)` 把最后一秒的状态丢掉。
  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    await TransferStore.save(tasks);
  }

  /// 状态变化后延迟落盘，避免高频进度回调把磁盘写满。
  void _scheduleSave() {
    if (_disposed) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 700), () {
      unawaited(TransferStore.save(tasks));
    });
  }

  /// 挂载配置被编辑后同步给队列：恢复出来的任务都用这里的挂载副本建连接，
  /// 不同步就会拿旧地址/旧代理去连。
  void syncMount(Mount mount) {
    _mounts[mount.id] = mount;
  }

  int get runningCount =>
      tasks.where((t) => t.status == TransferStatus.running).length;

  int get queuedCount => tasks.where((t) => t.status == TransferStatus.queued).length;

  double get totalSpeed => tasks
      .where((t) => t.status == TransferStatus.running)
      .fold(0.0, (s, t) => s + t.speed);

  // ---------- 入队 ----------

  /// 下载入口：文件直接入队，目录递归展开。返回入队文件数。
  Future<int> enqueueDownload(Mount mount, RemoteEntry entry) async {
    if (!entry.isDir) {
      final dir = await downloadDir(root: downloadRoot);
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
      return 1;
    }
    return _enqueueDirectory(mount, entry);
  }

  /// 目录下载：广度遍历远端目录，本地按同名层级建目录，逐个文件入队。
  ///
  /// 单独开一条连接做列举（与传输任务互不影响），列完即关。
  Future<int> _enqueueDirectory(Mount mount, RemoteEntry root) async {
    final base = await downloadDir(root: downloadRoot);
    final rootLocal = Directory(
        '${base.path}${Platform.pathSeparator}${sanitizeName(root.name)}');
    if (!rootLocal.existsSync()) await rootLocal.create(recursive: true);

    final driver = await createDriver(mount);
    _mounts[mount.id] = mount;
    var count = 0;
    try {
      await driver.connect();
      final stack = <List<String>>[
        [root.path, rootLocal.path],
      ];
      while (stack.isNotEmpty) {
        final cur = stack.removeLast();
        final List<RemoteEntry> items;
        try {
          items = await driver.list(cur[0]);
        } catch (_) {
          continue; // 子目录不可读时跳过，不阻断其余文件
        }
        for (final e in items) {
          final local = '${cur[1]}${Platform.pathSeparator}${sanitizeName(e.name)}';
          if (e.isDir) {
            try {
              await Directory(local).create(recursive: true);
            } catch (_) {}
            stack.add([e.path, local]);
          } else {
            tasks.insert(
              0,
              TransferTask(
                id: _newId(),
                mountId: mount.id,
                mountName: mount.name,
                name: e.name,
                remotePath: e.path,
                localPath: local,
                dir: TransferDir.download,
                total: e.size,
              ),
            );
            count++;
          }
        }
      }
    } finally {
      try {
        await driver.close();
      } catch (_) {}
    }
    _pump();
    return count;
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
      _scheduleSave();
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
    task.speed = 0;
    task.sampleAt = null;
    task.sampleBytes = task.transferred;
    task.error = null;
    task.status = TransferStatus.queued;
    _pump();
  }

  void retry(TransferTask task) => resume(task);

  /// 取消：中止并移出列表。半截下载文件一并清掉（用户明确放弃）。
  void cancel(TransferTask task) {
    task.abort = true;
    if (task.dir == TransferDir.download) _discardPartial(task.localPath);
    task.resumeOffset = 0;
    tasks.remove(task);
    _scheduleSave();
    notifyListeners();
  }

  void clearFinished() {
    tasks.removeWhere((t) => t.status == TransferStatus.done);
    _scheduleSave();
    notifyListeners();
  }

  /// 挂载被删除时清掉相关任务。
  void dropMount(String mountId) {
    _mounts.remove(mountId);
    for (final t in tasks.where((x) => x.mountId == mountId && x.isActive)) {
      t.abort = true;
    }
    tasks.removeWhere((x) => x.mountId == mountId);
    _scheduleSave();
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
    _scheduleSave();
    notifyListeners();
  }

  Future<void> _run(TransferTask task) async {
    final mount = _mounts[task.mountId];
    StorageDriver? driver;
    try {
      if (mount == null) throw DriverException('挂载已不存在，请重新添加后再试');
      driver = await createDriver(mount);
      await driver.connect();
      task.resumable = task.dir == TransferDir.download
          ? driver.resume.canDownload
          : driver.resume.canUpload;
      if (task.abort) throw const TransferAborted();

      if (task.dir == TransferDir.download) {
        final start = await _downloadStart(task, driver);
        if (start == 0) _discardPartial(task.localPath);
        task.transferred = start;
        await driver.downloadTo(
          task.remotePath,
          task.localPath,
          resumeFrom: start,
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
        final start = await _uploadStart(task, driver);
        task.transferred = start;
        await driver.uploadFile(
          task.localPath,
          task.remotePath,
          resumeFrom: start,
          onProgress: (done, total) => _onProgress(task, done, total),
        );
      }
      if (task.abort) throw const TransferAborted();
      task.status = TransferStatus.done;
      task.transferred = task.total > 0 ? task.total : task.transferred;
      task.resumeOffset = 0;
      task.speed = 0;
      task.finishedAt = DateTime.now();
    } on TransferAborted {
      if (tasks.contains(task)) {
        task.status = TransferStatus.paused;
        task.speed = 0;
        _markResumePoint(task);
      }
    } catch (e) {
      if (tasks.contains(task)) {
        // task.abort 说明是用户主动暂停：dio 会把「进度回调里抛的异常」包成
        // DioException，到不了上面的 TransferAborted 分支，这里兜一层，
        // 否则 WebDAV 上传 / S3 单次 PUT 的暂停会显示成「失败」。
        if (task.abort) {
          task.status = TransferStatus.paused;
          task.speed = 0;
          _markResumePoint(task);
        } else {
          task.status = TransferStatus.failed;
          task.speed = 0;
          task.error = shortError(e);
          _markResumePoint(task);
        }
      }
    } finally {
      task.abort = false;
      try {
        await driver?.close();
      } catch (_) {}
      _pump();
    }
  }

  /// 记下可续传的进度；不支持续传的下载直接删掉半截文件，避免占位误导。
  void _markResumePoint(TransferTask task) {
    task.resumeOffset = task.transferred;
    if (task.dir == TransferDir.download && !task.resumable) {
      _discardPartial(task.localPath);
      task.resumeOffset = 0;
      task.transferred = 0;
    }
  }

  /// 下载续传起点以本地文件真实长度为准（内存里的计数可能比落盘多）。
  Future<int> _downloadStart(TransferTask task, StorageDriver driver) async {
    if (task.resumeOffset <= 0 || !driver.resume.canDownload) return 0;
    try {
      final f = File(task.localPath);
      if (!f.existsSync()) return 0;
      final len = await f.length();
      if (len <= 0) return 0;
      if (task.total > 0 && len >= task.total) return 0;
      return len;
    } catch (_) {
      return 0;
    }
  }

  /// 上传续传起点交给驱动决定：HTTP 类按远端大小复核，S3 看分片状态。
  Future<int> _uploadStart(TransferTask task, StorageDriver driver) =>
      driver.uploadResumeOffset(task.localPath, task.remotePath, task.resumeOffset);

  void _onProgress(TransferTask task, int done, int total) {
    task.transferred = done;
    if (total > 0) task.total = total;
    if (task.abort) throw const TransferAborted();
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
    _saveTimer?.cancel();
    for (final t in tasks) {
      t.abort = true;
    }
    unawaited(TransferStore.save(tasks));
    super.dispose();
  }
}

/// 下载目录：优先用设置里指定的 [root]，否则按平台默认 ——
/// Windows 落在用户「下载」目录、Android 落在**公共**下载目录。
///
/// 指定目录不可用（被删、权限不足、路径变成了文件）时**静默回落**：
/// ① 用户目录 → ② 平台默认目录 → ③ 应用文档目录。
/// Android 10+ 的分区存储下没有「所有文件访问」权限时写不了
/// `/storage/emulated/0/Download`，写探针会发现并落到 ③，下载不会失败。
Future<Directory> downloadDir({String root = ''}) async {
  final custom = root.trim();
  if (custom.isNotEmpty) {
    final dir = await _ensureWritableDir(custom);
    if (dir != null) return dir;
  }

  final preferred = _platformDownloadPath();
  if (preferred != null) {
    final dir = await _ensureWritableDir(preferred);
    if (dir != null) return dir;
  }

  final base = await getApplicationDocumentsDirectory();
  final fallback = Directory('${base.path}${Platform.pathSeparator}Nimbo');
  return await _ensureWritableDir(fallback.path) ?? fallback;
}

/// 各平台的「下载」根目录（不含兜底）。返回 null 表示该平台没有约定位置。
String? _platformDownloadPath() {
  if (Platform.isWindows) {
    final home = Platform.environment['USERPROFILE'];
    if (home != null && home.isNotEmpty) return '$home\\Downloads\\Nimbo';
    return null;
  }
  if (Platform.isAndroid) {
    // 公共下载目录：文件管理器/微信/QQ 都能直接看到，比应用沙盒目录有用。
    return '/storage/emulated/0/Download/Nimbo';
  }
  return null;
}

/// 建目录 + 写一个空探针：`exists` 会撒谎（存在但只读、或路径变成了文件），
/// 真写一次才知道能不能落盘。不可用时返回 null。
Future<Directory?> _ensureWritableDir(String path) async {
  try {
    final dir = Directory(path);
    if (!dir.existsSync()) await dir.create(recursive: true);
    final probe = File('${dir.path}${Platform.pathSeparator}.nimbo-write-test');
    await probe.writeAsString('', flush: true);
    await probe.delete();
    return dir;
  } catch (_) {
    return null;
  }
}

