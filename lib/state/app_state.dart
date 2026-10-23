import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../core/store.dart';
import '../drivers/factory.dart';
import '../drivers/storage_driver.dart';

class AppState extends ChangeNotifier {
  final Prefs _prefs = Prefs.instance;

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
  final List<TransferTask> tasks = [];

  bool get hasMount => activeMount != null;
  bool get readOnly => activeMount?.readOnly ?? false;

  Future<void> boot() async {
    await _prefs.load();
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

  Future<Directory> _downloadDir() async {
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

  Future<void> download(RemoteEntry entry) async {
    final d = _driver;
    final mount = activeMount;
    if (d == null || mount == null || entry.isDir) return;
    final dir = await _downloadDir();
    final localPath = '${dir.path}${Platform.pathSeparator}${entry.name}';
    final task = TransferTask(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      mountName: mount.name,
      name: entry.name,
      remotePath: entry.path,
      localPath: localPath,
      total: entry.size,
      status: TransferStatus.running,
    );
    tasks.insert(0, task);
    notifyListeners();
    try {
      await d.downloadTo(entry.path, localPath, onProgress: (done, total) {
        task.transferred = done;
        if (total > 0) task.total = total;
        notifyListeners();
      });
      task.status = TransferStatus.done;
      task.transferred = task.total > 0 ? task.total : task.transferred;
    } catch (e) {
      task.status = TransferStatus.failed;
      task.error = e is DriverException ? e.message : '$e';
    }
    notifyListeners();
  }

  void clearFinishedTasks() {
    tasks.removeWhere((t) => t.status == TransferStatus.done);
    notifyListeners();
  }

  Future<void> updateSettings(void Function(AppSettings s) change) async {
    change(_prefs.settings);
    await _prefs.save();
    notifyListeners();
  }
}
