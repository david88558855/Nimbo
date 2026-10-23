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

/// 安全存储读取结果：ok=false 表示读取过程本身失败（不是"没存过"）。
class StoredSecret {
  const StoredSecret(this.value, {required this.ok});

  final String value;
  final bool ok;
}

class AppSettings {  bool hideHiddenFiles = false;
  bool confirmDelete = true;

  /// 并发传输数：每个任务独占一条连接。
  int maxConcurrent = 2;

  Map<String, dynamic> toJson() => {
        'hideHiddenFiles': hideHiddenFiles,
        'confirmDelete': confirmDelete,
        'maxConcurrent': maxConcurrent,
      };

  void load(Map<String, dynamic>? j) {
    if (j == null) return;
    hideHiddenFiles = j['hideHiddenFiles'] == true;
    confirmDelete = j['confirmDelete'] != false;
    final c = (j['maxConcurrent'] as num?)?.toInt() ?? 2;
    maxConcurrent = c < 1 ? 1 : (c > 4 ? 4 : c);
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

  /// 区分「没有存过」（ok=true, value 空）与「安全存储不可用」（ok=false）。
  /// 后者在 Android 上通常是 minSdk < 23 或设备 keystore 异常，必须先提示用户，
  /// 否则会被当成空密码，所有网络协议都表现成「认证失败」。
  static Future<StoredSecret> readSafe(String mountId, {String field = 'password'}) async {
    try {
      final v = await _storage.read(key: _key(mountId, field));
      return StoredSecret(v ?? '', ok: true);
    } catch (_) {
      return const StoredSecret('', ok: false);
    }
  }

  /// 写入凭据；返回 false 表示安全存储不可用（调用方应提示用户，否则会静默丢密码）。
  static Future<bool> write(String mountId, String value, {String field = 'password'}) async {
    try {
      if (value.isEmpty) {
        await _storage.delete(key: _key(mountId, field));
      } else {
        await _storage.write(key: _key(mountId, field), value: value);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> delete(String mountId) async {
    try {
      await _storage.delete(key: _key(mountId, 'password'));
      await _storage.delete(key: _key(mountId, 'proxyPassword'));
    } catch (_) {}
  }
}
