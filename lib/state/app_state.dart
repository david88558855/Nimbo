import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../core/format.dart';
import '../core/limiter.dart';
import '../core/models.dart';
import '../core/multipart_store.dart';
import '../core/store.dart';
import '../core/transfer_store.dart';
import '../core/upload_checkpoint.dart';
import '../drivers/errors.dart';
import '../drivers/factory.dart';
import '../drivers/storage_driver.dart';
import 'transfer_manager.dart';

class AppState extends ChangeNotifier {
  AppState() {
    transfers.addListener(_onTransfers);
  }

  final Prefs _prefs = Prefs.instance;

  /// 传输队列与当前浏览会话解耦：切换挂载不会打断正在跑的传输。
  final TransferManager transfers = TransferManager();

  int _seenDone = 0;

  /// 传输层每次变动都要刷新界面；此外在有任务完成时重列当前目录，
  /// 让刚上传的文件直接出现在列表里。
  void _onTransfers() {
    notifyListeners();
    final doneCount =
        transfers.tasks.where((t) => t.status == TransferStatus.done).length;
    if (doneCount != _seenDone) {
      _seenDone = doneCount;
      if (!browseAll && hasMount) unawaited(refresh());
    }
  }

  List<Mount> get mounts => _prefs.mounts;
  Mount? get activeMount => _prefs.activeMount;
  String? get activeId => _prefs.activeMountId;
  String get dataDirPath => _prefs.dataDirPath;
  bool get portable => _prefs.portable;
  AppSettings get settings => _prefs.settings;

  /// 每个挂载一条**常驻**会话：切换挂载只切换「当前浏览目标」，不再断开其它挂载
  /// （OpenList 式：多个存储同时在线，切回来是瞬时的，也不会打断进行中的操作）。
  final Map<String, StorageDriver> _sessions = <String, StorageDriver>{};

  /// 每个挂载上一次的连接错误（连上后在 [sessionFor] 里清掉）。
  final Map<String, String> _sessionErrors = <String, String>{};

  /// 当前浏览挂载所使用的会话。
  StorageDriver? get _driver => _sessions[_prefs.activeMountId];

  bool isConnected(String mountId) => _sessions.containsKey(mountId);
  String? mountError(String mountId) => _sessionErrors[mountId];

  String path = '/';
  List<RemoteEntry> entries = const [];

  /// 当前挂载的容量（协议不支持时为 null，界面显示「未知」）。
  SpaceInfo? space;
  bool loading = false;
  String? error;
  RemoteEntry? selected;

  /// 文件页是否停在「全部挂载」根（聚合视图）。启动与删除挂载后回到这里。
  bool browseAll = true;

  /// 多选（按 path 记录，刷新后自动丢弃已不存在的项）。
  final Set<String> _picked = <String>{};
  bool selectionMode = false;

  Set<String> get picked => _picked;
  int get pickedCount => _picked.length;
  bool isPicked(RemoteEntry entry) => _picked.contains(entry.path);

  List<RemoteEntry> get pickedEntries =>
      entries.where((e) => _picked.contains(e.path)).toList(growable: false);

  List<TransferTask> get tasks => transfers.tasks;

  bool get hasMount => activeMount != null;

  @override
  void dispose() {
    transfers.removeListener(_onTransfers);
    transfers.dispose();
    // 关掉所有挂载的会话（dispose 不能 await，发出即可）。
    for (final d in _sessions.values) {
      unawaited(d.close());
    }
    _sessions.clear();
    super.dispose();
  }

  /// 取（必要时建立）某个挂载的会话。
  ///
  /// [reconnect] 为 true 时先关掉旧会话再重连（改配置/换凭据后用）。
  /// 同一挂载永远只保留一个会话实例，避免连接泄漏。
  Future<StorageDriver> sessionFor(Mount mount, {bool reconnect = false}) async {
    final existing = _sessions[mount.id];
    if (existing != null && !reconnect) return existing;
    if (existing != null) {
      _sessions.remove(mount.id);
      try {
        await existing.close();
      } catch (_) {}
    }
    final d = await createDriver(mount);
    await d.connect();
    _sessions[mount.id] = d;
    _sessionErrors.remove(mount.id);
    return d;
  }

  /// 关掉并丢弃某个挂载的会话（删除挂载、改配置、连接失败时用）。
  Future<void> dropSession(String mountId) async {
    final d = _sessions.remove(mountId);
    _sessionErrors.remove(mountId);
    if (d != null) {
      try {
        await d.close();
      } catch (_) {}
    }
  }

  /// 启动后把所有挂载**同时**连上。
  ///
  /// 失败只记录到 [mountError]，绝不抛出：某个挂载的密码错了不该影响其它挂载。
  /// 并行发起，挂载数一般个位数，不需要限流。
  Future<void> warmUp() async {
    final list = List<Mount>.of(_prefs.mounts);
    if (list.isEmpty) return;
    await Future.wait(list.map(_warmOne));
    notifyListeners();
  }

  /// 连一个挂载：失败只记状态，不抛（`warmUp` 与「编辑后重连」共用）。
  Future<void> _warmOne(Mount m) async {
    if (_sessions.containsKey(m.id)) return;
    try {
      await sessionFor(m);
    } catch (e) {
      _sessionErrors[m.id] = describeError(e);
    }
  }

  Future<void> boot() async {
    await _prefs.load();
    _applyRuntimeSettings();
    // 恢复上次的传输记录：统一转成「已暂停」，由用户决定是否继续。
    final saved = await TransferStore.load();
    await transfers.restore(saved, _prefs.mounts);
    // 启动停在「全部挂载」：根目录先让用户看到所有挂载，而不是直接钻进上次那个。
    browseAll = true;
    notifyListeners();
    // 后台把所有挂载连上（不阻塞首帧，失败只影响该挂载的状态标记）。
    unawaited(warmUp());
  }

  /// 把设置里的「运行时参数」同步给传输层：并发数、下载目录与限速都只在启动/改设置时生效。
  void _applyRuntimeSettings() {
    transfers.maxConcurrent = _prefs.settings.maxConcurrent;
    transfers.downloadRoot = _prefs.settings.downloadDir;
    TransferLimiter.instance.configure(
      uploadKbps: _prefs.settings.uploadLimitKbps,
      downloadKbps: _prefs.settings.downloadLimitKbps,
    );
  }

  /// 回到「全部挂载」根，保留已建立的连接以便再次进入时更快。
  void showAll() {
    browseAll = true;
    loading = false;
    error = null;
    selected = null;
    space = null;
    _clearPicked();
    notifyListeners();
  }

  Future<void> open(Mount mount) async {
    browseAll = false;
    loading = true;
    error = null;
    entries = const [];
    space = null;
    selected = null;
    _clearPicked();
    path = '/';
    notifyListeners();
    try {
      // 复用已有会话：连过的挂载切回来是瞬时的，且不会把别的挂载踢下线。
      final d = await sessionFor(mount);
      _prefs.activeMountId = mount.id;
      await _prefs.save();
      entries = _visible(await d.list('/'));
      space = await _readSpace(d);
    } catch (e) {
      error = describeError(e);
      _sessionErrors[mount.id] = error!;
      // 连不上就别留着半个会话，下次进来重新握手。
      await dropSession(mount.id);
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// 容量读失败不影响浏览：只是显示「未知」。
  Future<SpaceInfo?> _readSpace(StorageDriver driver) async {
    try {
      return await driver.space();
    } catch (_) {
      return null;
    }
  }

  Future<void> refresh() async {
    final d = _driver;
    if (d == null) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      entries = _visible(await d.list(path));
    } catch (e) {
      error = describeError(e);
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> cd(String target) async {
    final d = _driver;
    if (d == null) return;
    final normalized = normalizePath(target);
    loading = true;
    error = null;
    selected = null;
    _clearPicked();
    notifyListeners();
    try {
      entries = _visible(await d.list(normalized));
      path = normalized;
    } catch (e) {
      error = describeError(e);
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> up() async {
    if (path == '/') {
      showAll();
      return;
    }
    await cd(parentPath(path));
  }

  void select(RemoteEntry? entry) {
    if (selected?.path == entry?.path) return;
    selected = entry;
    notifyListeners();
  }

  // ---------- 多选 ----------

  void beginSelection([RemoteEntry? seed]) {
    selectionMode = true;
    selected = null;
    if (seed != null) _picked.add(seed.path);
    notifyListeners();
  }

  void togglePicked(RemoteEntry entry) {
    if (!_picked.remove(entry.path)) _picked.add(entry.path);
    notifyListeners();
  }

  void pickAll() {
    _picked
      ..clear()
      ..addAll(entries.map((e) => e.path));
    selectionMode = true;
    notifyListeners();
  }

  void exitSelection() {
    _clearPicked();
    notifyListeners();
  }

  void _clearPicked() {
    _picked.clear();
    selectionMode = false;
  }

  List<RemoteEntry> _visible(List<RemoteEntry> all) {
    final hide = _prefs.settings.hideHiddenFiles;
    final list =
        hide ? all.where((e) => !e.name.startsWith('.')).toList(growable: false) : all;
    if (_picked.isNotEmpty) {
      final alive = list.map((e) => e.path).toSet();
      _picked.removeWhere((p) => !alive.contains(p));
    }
    return list;
  }

  /// 批量下载：目录递归展开，返回入队文件数。
  Future<int> downloadPicked() async {
    final mount = activeMount;
    if (mount == null) return 0;
    final targets = pickedEntries.toList(growable: false);
    var n = 0;
    for (final e in targets) {
      n += await transfers.enqueueDownload(mount, e);
    }
    exitSelection();
    return n;
  }

  /// 批量删除：串行执行，全部尝试一遍后汇总失败项。
  Future<int> deletePicked() async {
    final d = _driver;
    if (d == null) return 0;
    final targets = pickedEntries.toList(growable: false);
    final failures = <String>[];
    var ok = 0;
    for (final e in targets) {
      try {
        await d.removeEntry(e);
        ok++;
      } catch (err) {
        failures.add('${e.name}：$err');
      }
    }
    if (selected != null && _picked.contains(selected!.path)) selected = null;
    exitSelection();
    await refresh();
    if (failures.isNotEmpty) {
      throw DriverException(
          '${failures.length} 项删除失败（成功 $ok 项）：${failures.first}');
    }
    return ok;
  }

  /// 读取远端文件内容（预览用）。
  Future<Uint8List> readEntry(RemoteEntry entry) async {
    final d = _driver;
    if (d == null) throw DriverException('当前没有打开的挂载');
    return d.readAll(entry.path);
  }

  Future<void> addMount(Mount mount, {String password = '', String proxyPassword = ''}) async {
    final okMain = await SecureStore.write(mount.id, password);
    final okProxy =
        await SecureStore.write(mount.id, proxyPassword, field: 'proxyPassword');
    if (password.isNotEmpty && !okMain) {
      throw DriverException(
        '密码无法写入系统凭据库（权限或密钥库异常），现在添加会导致下次启动丢失密码。'
        '请检查系统凭据管理器后重试。',
        kind: DriverErrorKind.auth,
      );
    }
    if (proxyPassword.isNotEmpty && !okProxy) {
      throw DriverException('代理密码无法写入系统凭据库，请检查权限后重试。',
          kind: DriverErrorKind.auth);
    }
    _prefs.mounts.add(mount);
    transfers.syncMount(mount);
    _prefs.activeMountId = mount.id;
    await _prefs.save();
    notifyListeners();
    await open(mount);
  }

  /// 编辑已保存的挂载：凭据留空表示不改，避免用户为了改个名字要重输密码。
  Future<void> updateMount(
    Mount next, {
    String? password,
    String? proxyPassword,
  }) async {
    final index = _prefs.mounts.indexWhere((m) => m.id == next.id);
    if (index < 0) throw DriverException('挂载已不存在，请刷新后重试');
    if (password != null && password.isNotEmpty) {
      final ok = await SecureStore.write(next.id, password);
      if (!ok) {
        throw DriverException(
          '密码无法写入系统凭据库（权限或密钥库异常），修改未保存。',
          kind: DriverErrorKind.auth,
        );
      }
    }
    if (proxyPassword != null && proxyPassword.isNotEmpty) {
      final ok = await SecureStore.write(next.id, proxyPassword, field: 'proxyPassword');
      if (!ok) {
        throw DriverException('代理密码无法写入系统凭据库，修改未保存。',
            kind: DriverErrorKind.auth);
      }
    }
    _prefs.mounts[index] = next;
    transfers.syncMount(next);
    // 连接参数可能变了：丢掉旧会话，正在浏览时立刻用新配置重连。
    await dropSession(next.id);
    await _prefs.save();
    notifyListeners();
    // 正在浏览这个挂载时立刻重连，让新配置生效（连接参数变了，旧会话没意义）；
    // 不是当前挂载也在后台重连，否则「所有挂载常驻在线」就断了一个。
    if (!browseAll && _prefs.activeMountId == next.id) {
      await open(next);
    } else {
      unawaited(_warmOne(next).then((_) => notifyListeners()));
    }
  }

  /// 已保存挂载的「测试连接」：凭据从安全存储取。
  Future<int> testSavedMount(Mount mount) => testMountWithStoredPassword(mount);

  Future<void> removeMount(Mount mount) async {
    final browsing = !browseAll && _prefs.activeMountId == mount.id;
    _prefs.mounts.removeWhere((m) => m.id == mount.id);
    await SecureStore.delete(mount.id);
    transfers.dropMount(mount.id);
    // 顺手清掉这个挂载的中间状态（S3 分片表 / WebDAV 上传断点），
    // 否则删了挂载还留着一堆再也用不上的记录。
    unawaited(MultipartStore.dropMount(mount.id));
    unawaited(UploadCheckpointStore.dropMount(mount.id));
    if (_prefs.activeMountId == mount.id) {
      _prefs.activeMountId = _prefs.mounts.isEmpty ? null : _prefs.mounts.first.id;
    }
    if (browsing) {
      entries = const [];
      error = null;
    }
    await dropSession(mount.id);
    await _prefs.save();
    if (browsing) {
      showAll();
    } else {
      notifyListeners();
    }
  }

  Future<void> createFolder(String name) async {
    final d = _driver;
    if (d == null) return;
    await d.mkdir(joinPath(path, name));
    await refresh();
  }

  Future<void> deleteEntry(RemoteEntry entry) async {
    final d = _driver;
    if (d == null) return;
    await d.removeEntry(entry);
    if (selected?.path == entry.path) selected = null;
    await refresh();
  }

  Future<void> renameEntry(RemoteEntry entry, String newName) async {
    final d = _driver;
    if (d == null) return;
    await d.move(entry.path, joinPath(parentPath(entry.path), newName));
    await refresh();
  }

  /// 复制或移动若干条目到 `targetMount` 的 [targetPath] 下。
  ///
  /// 三种路径，按代价从低到高：
  /// - **同挂载 + 移动**：直接 `move()`（= rename），目录也是整体 rename，最快；
  /// - **同挂载 + 复制**：交给驱动的 `copyEntry`（WebDAV 走服务端 `COPY`、
  ///   本地走 `File.copy`，其余协议回落成临时文件中转）；
  /// - **跨挂载**：逐文件「下载到临时文件 → 上传」，目录递归展开，移动成功后再删源。
  ///
  /// 返回处理的**文件**数（目录本身不计数）。单项失败不中断整批，最后汇总抛出。
  Future<int> copyOrMoveEntries(
    List<RemoteEntry> sources, {
    required Mount targetMount,
    required String targetPath,
    required bool move,
  }) async {
    final sourceMount = activeMount;
    if (sourceMount == null) throw DriverException('请先打开一个挂载');
    if (sources.isEmpty) return 0;

    final destDir = normalizePath(targetPath);
    final sameMount = sourceMount.id == targetMount.id;
    if (sameMount) {
      // 目录不能放进自己或自己的子目录里，否则递归会把新文件再拷一遍。
      for (final e in sources) {
        if (e.isDir && (destDir == e.path || destDir.startsWith('${e.path}/'))) {
          throw DriverException('不能把「${e.name}」放进它自己或它的子目录');
        }
      }
    }

    final src = await sessionFor(sourceMount);
    final dst = sameMount ? src : await sessionFor(targetMount);
    var done = 0;
    final failures = <String>[];
    for (final e in sources) {
      try {
        done += await _copyTree(src, dst, e, destDir, move: move, sameMount: sameMount);
      } catch (err) {
        failures.add('${e.name}：${describeError(err)}');
      }
    }
    if (!browseAll) await refresh();
    if (failures.isNotEmpty) {
      throw DriverException(
          '${failures.length} 项未完成（已处理 $done 个文件）：${failures.first}');
    }
    return done;
  }

  Future<int> _copyTree(
    StorageDriver src,
    StorageDriver dst,
    RemoteEntry e,
    String destDir, {
    required bool move,
    required bool sameMount,
  }) async {
    final dest = joinPath(destDir, e.name);

    if (!e.isDir) {
      if (sameMount) {
        if (move) {
          await src.move(e.path, dest);
        } else {
          await src.copyEntry(e, dest);
        }
      } else {
        await _streamCopy(src, dst, e, dest);
        if (move) await src.removeEntry(e);
      }
      return 1;
    }

    // 目录 + 同挂载 + 移动：整体 rename，一次系统调用搞定。
    if (sameMount && move) {
      await src.move(e.path, dest);
      return 1;
    }

    try {
      await dst.mkdir(dest);
    } catch (_) {
      // 已存在会报错，忽略即可（后面按同名覆盖）
    }
    var n = 0;
    for (final child in await src.list(e.path)) {
      n += await _copyTree(src, dst, child, dest, move: move, sameMount: sameMount);
    }
    if (move) await src.removeEntry(e);
    return n;
  }

  /// 跨挂载搬运单个文件：下载到系统临时目录再上传，完成后删临时文件。
  Future<void> _streamCopy(
      StorageDriver src, StorageDriver dst, RemoteEntry e, String dest) async {
    final tmp = File('${Directory.systemTemp.path}${Platform.pathSeparator}'
        'nimbo-xfer-${DateTime.now().microsecondsSinceEpoch}-${e.name}');
    try {
      await src.downloadTo(e.path, tmp.path);
      await dst.uploadFile(tmp.path, dest);
    } finally {
      try {
        if (tmp.existsSync()) await tmp.delete();
      } catch (_) {}
    }
  }

  /// 下载到本地下载目录（排队执行，不阻塞当前浏览）。目录会递归展开。
  Future<int> download(RemoteEntry entry) async {
    final mount = activeMount;
    if (mount == null) return 0;
    return transfers.enqueueDownload(mount, entry);
  }

  /// 上传本地文件到当前目录。
  Future<void> uploadFiles(List<String> localPaths) async {
    final mount = activeMount;
    if (mount == null || localPaths.isEmpty) return;
    final current = path;
    for (final p in localPaths) {
      await transfers.enqueueUpload(mount, p, current);
    }
  }

  /// 上传整个本地目录到当前目录（保留层级）。
  Future<int> uploadFolder(String localDir) async {
    final mount = activeMount;
    if (mount == null) return 0;
    return transfers.enqueueUploadDir(mount, localDir, path);
  }

  void clearFinishedTasks() => transfers.clearFinished();

  /// 退出前的落盘：配置与传输记录都立刻写一次。
  ///
  /// `exit(0)` 不会走 `dispose()`，所以托盘「退出」必须先调这里，
  /// 否则最后一次改的设置、以及最后 700ms 内的传输进度会丢。
  Future<void> flush() async {
    try {
      await _prefs.save();
    } catch (_) {}
    await transfers.flush();
  }

  Future<void> updateSettings(void Function(AppSettings s) change) async {
    final beforeHidden = _prefs.settings.hideHiddenFiles;
    change(_prefs.settings);
    _applyRuntimeSettings();
    await _prefs.save();
    notifyListeners();
    // 隐藏文件开关直接影响当前列表，改完要按新规则重筛一次。
    if (beforeHidden != _prefs.settings.hideHiddenFiles &&
        !browseAll &&
        hasMount) {
      unawaited(refresh());
    }
  }
}
