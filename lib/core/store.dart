import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
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

class AppSettings {
  /// 是否隐藏以 `.` 开头的文件/目录。**默认开启**：Linux 风格的 dotfile、
  /// 各类同步工具的临时目录（`.git`、`.DS_Store`、`.thumbnails`）平时不需要看到，
  /// 需要时在设置里关掉即可。
  bool hideHiddenFiles = true;
  bool confirmDelete = true;

  /// 关窗行为：true = 收进托盘（默认），false = 直接退出。
  bool closeToTray = true;

  /// 并发传输数：每个任务独占一条连接。默认 3。
  int maxConcurrent = 3;

  /// 用户是否**显式**选过并发数。
  ///
  /// 老版本每次保存都会把默认值 2 写进 `prefs.json`，所以「字段存在」不能证明
  /// 用户选过 2。默认值改成 3 之后，只有这个标记为 true 才保留历史值，
  /// 否则一律按新默认值 3 起（用户不改的话不该被旧默认值粘住）。
  bool maxConcurrentPinned = false;

  /// 下载目录（留空 = 默认：Windows 是「下载/Nimbo」，其余是应用文档目录/Nimbo）。
  ///
  /// 存绝对路径；目录被删或不可写时传输层会回落到默认目录，不会让下载直接失败。
  String downloadDir = '';

  /// 全局限速（KB/s，0 表示不限）。按方向分开配，因为上下行的带宽通常不对称。
  int uploadLimitKbps = 0;
  int downloadLimitKbps = 0;

  Map<String, dynamic> toJson() => {
        'hideHiddenFiles': hideHiddenFiles,
        'confirmDelete': confirmDelete,
        'closeToTray': closeToTray,
        'maxConcurrent': maxConcurrent,
        'maxConcurrentPinned': maxConcurrentPinned,
        'downloadDir': downloadDir,
        'uploadLimitKbps': uploadLimitKbps,
        'downloadLimitKbps': downloadLimitKbps,
      };

  void load(Map<String, dynamic>? j) {
    if (j == null) return;
    // 缺省 true：老配置里没有这个键时按「隐藏」处理；显式写 false 才展开。
    hideHiddenFiles = j['hideHiddenFiles'] != false;
    confirmDelete = j['confirmDelete'] != false;
    closeToTray = j['closeToTray'] != false;
    final c = (j['maxConcurrent'] as num?)?.toInt();
    maxConcurrentPinned = j['maxConcurrentPinned'] == true;
    maxConcurrent = (maxConcurrentPinned && c != null) ? _clampConcurrent(c) : 3;
    downloadDir = (j['downloadDir'] as String?) ?? '';
    uploadLimitKbps = _clampKbps((j['uploadLimitKbps'] as num?)?.toInt());
    downloadLimitKbps = _clampKbps((j['downloadLimitKbps'] as num?)?.toInt());
  }

  static int _clampConcurrent(int v) => v < 1 ? 1 : (v > 4 ? 4 : v);

  /// 上限 1 GB/s：再大没有意义，也避免手输错误把令牌桶计算出天文数字。
  static int _clampKbps(int? v) {
    final n = v ?? 0;
    if (n <= 0) return 0;
    return n > 1024 * 1024 ? 1024 * 1024 : n;
  }
}

/// 解析 `prefs.json` 里的挂载列表：**逐条容错**，坏条目跳过并计数。
///
/// 之前用的是 `whereType().map(Mount.fromJson)` 惰性链：任一条目抛错就中断
/// `addAll`，而 `mounts` 已经被 `clear()` 过 —— 结果是「后面所有挂载消失」，
/// 且下一次保存会把这份残缺列表写回磁盘，等于永久删除（BUG-02）。
/// 抽成纯函数便于单测（不碰文件系统、不依赖插件）。
({List<Mount> mounts, int skipped}) parseMounts(Object? raw) {
  final out = <Mount>[];
  var skipped = 0;
  if (raw is! List) return (mounts: out, skipped: skipped);
  for (final item in raw) {
    if (item is! Map<String, dynamic>) {
      skipped++;
      continue;
    }
    try {
      final m = Mount.fromJson(item);
      if (m.id.isEmpty) {
        skipped++;
        continue;
      }
      out.add(m);
    } catch (_) {
      skipped++;
    }
  }
  return (mounts: out, skipped: skipped);
}

class Prefs {
  Prefs._();
  static final Prefs instance = Prefs._();

  final List<Mount> mounts = [];
  String? activeMountId;
  final AppSettings settings = AppSettings();
  String dataDirPath = '';
  bool portable = false;

  /// 保存串行化用：多个调用方（`open` / `updateSettings` / 退出 `flush`）
  /// 可能并发触发保存，必须排队执行，否则两路会同时写同一个临时文件（BUG-01）。
  Future<void> _writing = Future<void>.value();

  Future<void> load() async {
    final dir = await AppPaths.dataDir();
    dataDirPath = dir.path;
    portable = Platform.isWindows && dir.path.contains('userdata') &&
        dir.path.startsWith(File(Platform.resolvedExecutable).parent.path);
    final f = File(await AppPaths.prefsFile());
    if (!f.existsSync()) return;

    Object? decoded;
    try {
      decoded = jsonDecode(await f.readAsString());
    } catch (_) {
      // 整份 JSON 坏掉：留一份备份，按空配置启动（不阻塞进应用）。
      await _backupBroken(f, 'corrupt');
      return;
    }
    if (decoded is! Map<String, dynamic>) {
      await _backupBroken(f, 'format');
      return;
    }

    final parsed = parseMounts(decoded['mounts']);
    mounts
      ..clear()
      ..addAll(parsed.mounts);
    // 有条目解析失败时先备份原文件：这份列表随时可能被下一次保存覆盖。
    if (parsed.skipped > 0) {
      await _backupBroken(f, 'entries');
    }

    activeMountId = decoded['activeMountId'] as String?;
    settings.load(decoded['settings'] as Map<String, dynamic>?);
  }

  /// 把读坏的配置留一份 `prefs.json.bak-<原因>-<时间>`，避免被后续保存覆盖。
  Future<void> _backupBroken(File f, String tag) async {
    try {
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .replaceAll('.', '-');
      await f.copy('${f.path}.bak-$tag-$stamp');
    } catch (_) {
      // 备份失败不影响启动
    }
  }

  /// 保存配置。**串行执行**：同时来多次保存会排队，最后一次写入的一定是最新状态。
  Future<void> save() {
    final next = _writing.then((_) => _saveNow());
    // 单次失败不能把后续保存全卡死：链上吞掉错误，错误仍会抛给本次调用方。
    _writing = next.catchError((Object _) {});
    return next;
  }

  Future<void> _saveNow() async {
    final data = {
      'version': 1,
      'mounts': mounts.map((m) => m.toJson()).toList(),
      'activeMountId': activeMountId,
      'settings': settings.toJson(),
    };
    final path = await AppPaths.prefsFile();
    // 每次用唯一临时名：即使有意外并发也不会互相写坏同一份 .tmp；
    // 最后一步 rename 在 Windows 上是原子的。
    final tmp = File('$path.${DateTime.now().microsecondsSinceEpoch}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    try {
      await tmp.rename(path);
    } on FileSystemException {
      // 目标被占用（杀毒/索引）时退回覆盖写，再删临时文件。
      await File(path).writeAsString(await tmp.readAsString());
      try {
        await tmp.delete();
      } catch (_) {}
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
  ///
  /// Windows 便携版额外读一份 `userdata/credentials.dat`：整目录拷到另一台机器
  /// 时系统凭据库是空的，用它兜底（见 [write]）。
  static Future<StoredSecret> readSafe(String mountId, {String field = 'password'}) async {
    final secure = await _secureRead(mountId, field);
    if (secure.value.isNotEmpty) return secure;
    final portable = await _portableGet(_key(mountId, field));
    if (portable != null && portable.isNotEmpty) {
      return StoredSecret(portable, ok: true);
    }
    return secure;
  }

  static Future<StoredSecret> _secureRead(String mountId, String field) async {
    try {
      final v = await _storage.read(key: _key(mountId, field));
      return StoredSecret(v ?? '', ok: true);
    } catch (_) {
      return const StoredSecret('', ok: false);
    }
  }

  /// 写入凭据；返回 false 表示安全存储不可用（调用方应提示用户，否则会静默丢密码）。
  static Future<bool> write(String mountId, String value, {String field = 'password'}) async {
    var secureOk = false;
    try {
      if (value.isEmpty) {
        await _storage.delete(key: _key(mountId, field));
      } else {
        await _storage.write(key: _key(mountId, field), value: value);
      }
      secureOk = true;
    } catch (_) {
      secureOk = false;
    }
    await _portablePut(_key(mountId, field), value);
    // Windows 上便携文件写成功也算成功（系统凭据库不可用时仍可工作）
    return secureOk || Platform.isWindows;
  }

  static Future<void> delete(String mountId) async {
    try {
      await _storage.delete(key: _key(mountId, 'password'));
      await _storage.delete(key: _key(mountId, 'proxyPassword'));
    } catch (_) {}
    await _portablePut(_key(mountId, 'password'), '');
    await _portablePut(_key(mountId, 'proxyPassword'), '');
  }

  // ---------- Windows 便携凭据（随 userdata 目录走）----------

  static File? _portableFileCache;

  static Future<File> _portableFile() async {
    final cached = _portableFileCache;
    if (cached != null) return cached;
    final dir = await AppPaths.dataDir();
    final f = File('${dir.path}${Platform.pathSeparator}credentials.dat');
    _portableFileCache = f;
    return f;
  }

  /// 固定派生密钥：换机器/换目录仍可解，纯混淆，仅防肉眼直读，
  /// **不等同于系统凭据库强度**。同机上仍以 DPAPI 存储为准。
  static final List<int> _portableKey =
      sha256.convert(utf8.encode('nimbo.portable.credential.v1')).bytes;

  static String _mask(String plain) {
    final key = _portableKey;
    final bytes = Uint8List.fromList(utf8.encode(plain));
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] ^= key[i % key.length];
    }
    return base64.encode(bytes);
  }

  static String _unmask(String stored) {
    final key = _portableKey;
    final bytes = base64.decode(stored);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] ^= key[i % key.length];
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static Future<Map<String, dynamic>> _portableAll() async {
    try {
      final f = await _portableFile();
      if (!f.existsSync()) return <String, dynamic>{};
      final raw = jsonDecode(await f.readAsString());
      if (raw is Map) return raw.cast<String, dynamic>();
      return <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  static Future<String?> _portableGet(String key) async {
    if (!Platform.isWindows) return null;
    final all = await _portableAll();
    final v = all[key];
    if (v is! String || v.isEmpty) return null;
    try {
      return _unmask(v);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _portablePut(String key, String value) async {
    if (!Platform.isWindows) return;
    try {
      final all = await _portableAll();
      if (value.isEmpty) {
        all.remove(key);
      } else {
        all[key] = _mask(value);
      }
      final f = await _portableFile();
      await f.writeAsString(jsonEncode(all));
    } catch (_) {}
  }
}
