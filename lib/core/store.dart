import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'models.dart';

/// 数据目录：Windows 优先跟随程序目录（便携），不可写时退回系统目录。
class AppPaths {
  static Directory? _cached;

  static Future<Directory> dataDir() async {
    if (_cached != null) return _cached!;
    if (Platform.isWindows) {
      final exeDir = File(Platform.resolvedExecutable).parent;
      final portable = Directory('${exeDir.path}${Platform.pathSeparator}userdata');
      if (await _writable(portable)) {
        _cached = portable;
        return portable;
      }
    }
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}userdata');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _cached = dir;
    return dir;
  }

  static Future<bool> _writable(Directory dir) async {
    try {
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final probe = File('${dir.path}${Platform.pathSeparator}.probe');
      await probe.writeAsString('ok');
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<String> prefsFile() async {
    final d = await dataDir();
    return '${d.path}${Platform.pathSeparator}prefs.json';
  }
}

class AppSettings {
  bool hideHiddenFiles = false;
  bool confirmDelete = true;

  Map<String, dynamic> toJson() => {
        'hideHiddenFiles': hideHiddenFiles,
        'confirmDelete': confirmDelete,
      };

  void load(Map<String, dynamic>? j) {
    if (j == null) return;
    hideHiddenFiles = j['hideHiddenFiles'] == true;
    confirmDelete = j['confirmDelete'] != false;
  }
}

class Prefs {
  Prefs._();
  static final Prefs instance = Prefs._();

  final List<Mount> mounts = [];
  String? activeMountId;
  final AppSettings settings = AppSettings();
  String dataDirPath = '';
  bool portable = false;

  Future<void> load() async {
    final dir = await AppPaths.dataDir();
    dataDirPath = dir.path;
    portable = Platform.isWindows && dir.path.contains('userdata') &&
        dir.path.startsWith(File(Platform.resolvedExecutable).parent.path);
    final f = File(await AppPaths.prefsFile());
    if (!f.existsSync()) return;
    try {
      final raw = jsonDecode(await f.readAsString());
      if (raw is! Map<String, dynamic>) return;
      final list = raw['mounts'];
      if (list is List) {
        mounts
          ..clear()
          ..addAll(list
              .whereType<Map<String, dynamic>>()
              .map(Mount.fromJson)
              .where((m) => m.id.isNotEmpty));
      }
      activeMountId = raw['activeMountId'] as String?;
      settings.load(raw['settings'] as Map<String, dynamic>?);
    } catch (_) {
      // 配置损坏时按空配置启动，不阻塞进入应用
    }
  }

  Future<void> save() async {
    final data = {
      'version': 1,
      'mounts': mounts.map((m) => m.toJson()).toList(),
      'activeMountId': activeMountId,
      'settings': settings.toJson(),
    };
    final path = await AppPaths.prefsFile();
    final tmp = File('$path.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    try {
      await tmp.rename(path);
    } on FileSystemException {
      await File(path).writeAsString(await tmp.readAsString());
      await tmp.delete();
    }
  }

  Mount? get activeMount {
    if (mounts.isEmpty) return null;
    final id = activeMountId;
    if (id == null) return mounts.first;
    for (final m in mounts) {
      if (m.id == id) return m;
    }
    return mounts.first;
  }
}

/// 凭据只进系统安全存储，不写进 prefs.json。
class SecureStore {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static String _key(String mountId, String field) => 'nimbo.$mountId.$field';

  static Future<String> read(String mountId, {String field = 'password'}) async {
    try {
      return await _storage.read(key: _key(mountId, field)) ?? '';
    } catch (_) {
      return '';
    }
  }

  static Future<void> write(String mountId, String value, {String field = 'password'}) async {
    try {
      if (value.isEmpty) {
        await _storage.delete(key: _key(mountId, field));
      } else {
        await _storage.write(key: _key(mountId, field), value: value);
      }
    } catch (_) {
      // 安全存储不可用时静默降级为无凭据（下次连接会提示重新输入）
    }
  }

  static Future<void> delete(String mountId) async {
    try {
      await _storage.delete(key: _key(mountId, 'password'));
      await _storage.delete(key: _key(mountId, 'proxyPassword'));
    } catch (_) {}
  }
}
