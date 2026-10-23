import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../core/store.dart';
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
      if (hasMount) unawaited(refresh());
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
    final mount = activeMount;
    if (mount != null) {
      await open(mount);
    } else {
      notifyListeners();
    }
  }

  Future<void> open(Mount mount) async {
    loading = true;
    error = null;
    entries = const [];
    selected = null;
    path = '/';
    notifyListeners();
    try {
      await _driver?.close();
      final d = await createDriver(mount);
      await d.connect();
      _driver = d;
      _prefs.activeMountId = mount.id;
      await _prefs.save();
      entries = await d.list('/');
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
      entries = await d.list(path);
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
    notifyListeners();
    try {
      entries = await d.list(normalized);
      path = normalized;
    } catch (e) {
      error = e is DriverException ? e.message : '$e';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> up() => cd(parentPath(path));

  void select(RemoteEntry? entry) {
    if (selected?.path == entry?.path) return;
    selected = entry;
    notifyListeners();
  }

  Future<void> addMount(Mount mount, {String password = '', String proxyPassword = ''}) async {
    await SecureStore.write(mount.id, password);
    await SecureStore.write(mount.id, proxyPassword, field: 'proxyPassword');
    _prefs.mounts.add(mount);
    _prefs.activeMountId = mount.id;
    await _prefs.save();
    notifyListeners();
    await open(mount);
  }

  Future<void> removeMount(Mount mount) async {
    final isActive = mount.id == _prefs.activeMountId;
    _prefs.mounts.removeWhere((m) => m.id == mount.id);
    await SecureStore.delete(mount.id);
    transfers.dropMount(mount.id);
    if (isActive) {
      _prefs.activeMountId = _prefs.mounts.isEmpty ? null : _prefs.mounts.first.id;
      await _driver?.close();
      _driver = null;
    }
    await _prefs.save();
    if (isActive) {
      final next = activeMount;
      if (next != null) {
        await open(next);
      } else {
        entries = const [];
        error = null;
        notifyListeners();
      }
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

  /// 下载到本地下载目录（排队执行，不阻塞当前浏览）。
  Future<void> download(RemoteEntry entry) async {
    final mount = activeMount;
    if (mount == null || entry.isDir) return;
    await transfers.enqueueDownload(mount, entry);
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

  void clearFinishedTasks() => transfers.clearFinished();

  Future<void> updateSettings(void Function(AppSettings s) change) async {
    change(_prefs.settings);
    transfers.maxConcurrent = _prefs.settings.maxConcurrent;
    await _prefs.save();
    notifyListeners();
  }
}
