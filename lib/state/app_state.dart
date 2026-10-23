import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../core/store.dart';
import '../core/transfer_store.dart';
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

  StorageDriver? _driver;
  String path = '/';
  List<RemoteEntry> entries = const [];
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
  bool get readOnly => activeMount?.readOnly ?? false;

  @override
  void dispose() {
    transfers.removeListener(_onTransfers);
    transfers.dispose();
    super.dispose();
  }

  Future<void> boot() async {
    await _prefs.load();
    transfers.maxConcurrent = _prefs.settings.maxConcurrent;
    // 恢复上次的传输记录：统一转成「已暂停」，由用户决定是否继续。
    final saved = await TransferStore.load();
    await transfers.restore(saved, _prefs.mounts.map((m) => m.id).toSet());
    // 启动停在「全部挂载」：根目录先让用户看到所有挂载，而不是直接钻进上次那个。
    browseAll = true;
    notifyListeners();
  }

  /// 回到「全部挂载」根，保留已建立的连接以便再次进入时更快。
  void showAll() {
    browseAll = true;
    loading = false;
    error = null;
    selected = null;
    _clearPicked();
    notifyListeners();
  }

  Future<void> open(Mount mount) async {
    browseAll = false;
    loading = true;
    error = null;
    entries = const [];
    selected = null;
    _clearPicked();
    path = '/';
    notifyListeners();
    try {
      await _driver?.close();
      final d = await createDriver(mount);
      await d.connect();
      _driver = d;
      _prefs.activeMountId = mount.id;
      await _prefs.save();
      entries = _visible(await d.list('/'));
    } catch (e) {
      _driver = null;
      error = e is DriverException ? e.message : '$e';
    } finally {
      loading = false;
      notifyListeners();
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
      error = e is DriverException ? e.message : '$e';
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
      error = e is DriverException ? e.message : '$e';
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
    _prefs.activeMountId = mount.id;
    await _prefs.save();
    notifyListeners();
    await open(mount);
  }

  Future<void> removeMount(Mount mount) async {
    final browsing = !browseAll && _prefs.activeMountId == mount.id;
    _prefs.mounts.removeWhere((m) => m.id == mount.id);
    await SecureStore.delete(mount.id);
    transfers.dropMount(mount.id);
    if (_prefs.activeMountId == mount.id) {
      _prefs.activeMountId = _prefs.mounts.isEmpty ? null : _prefs.mounts.first.id;
    }
    if (browsing) {
      await _driver?.close();
      _driver = null;
      entries = const [];
      error = null;
    }
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

  /// 下载到本地下载目录（排队执行，不阻塞当前浏览）。目录会递归展开。
  Future<int> download(RemoteEntry entry) async {
    final mount = activeMount;
    if (mount == null) return 0;
    return transfers.enqueueDownload(mount, entry);
  }

  /// 上传本地文件到当前目录。
  Future<void> uploadFiles(List<String> localPaths) async {
    final mount = activeMount;
    if (mount == null || readOnly || localPaths.isEmpty) return;
    final current = path;
    for (final p in localPaths) {
      await transfers.enqueueUpload(mount, p, current);
    }
  }

  /// 上传整个本地目录到当前目录（保留层级）。
  Future<int> uploadFolder(String localDir) async {
    final mount = activeMount;
    if (mount == null || readOnly) return 0;
    return transfers.enqueueUploadDir(mount, localDir, path);
  }

  void clearFinishedTasks() => transfers.clearFinished();

  Future<void> updateSettings(void Function(AppSettings s) change) async {
    change(_prefs.settings);
    transfers.maxConcurrent = _prefs.settings.maxConcurrent;
    await _prefs.save();
    notifyListeners();
  }
}
