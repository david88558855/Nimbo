import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../core/format.dart';
import '../core/models.dart';
import 'storage_driver.dart';

/// SFTP：dartssh2 纯 Dart 实现。
/// P0 限制：直连；经代理复用同一隧道需要自定义 SSHSocket，放在下一阶段。
class SftpDriver extends StorageDriver {
  SftpDriver(super.mount, {required this.password, required this.proxy});

  final String password;
  final ProxyConfig proxy;

  SSHClient? _client;
  SftpClient? _sftp;

  static const _memoryLimit = 64 * 1024 * 1024;

  @override
  String get scheme => 'sftp';

  @override
  Capability get caps => const Capability(space: false, move: true);

  @override
  Future<void> connect() async {
    if (proxy.enabled) {
      throw DriverException(
        'SFTP 经代理连接将在下一阶段支持：当前请先直连该主机',
        kind: DriverErrorKind.unsupported,
      );
    }
    final host = mount.host.trim();
    if (host.isEmpty) throw DriverException('请填写主机地址');
    final port = mount.port == 0 ? 22 : mount.port;
    try {
      final socket = await SSHSocket.connect(host, port);
      final client = SSHClient(
        socket,
        username: mount.username,
        onPasswordRequest: () => password,
      );
      _client = client;
      _sftp = await client.sftp();
    } catch (e) {
      final msg = '$e';
      final lower = msg.toLowerCase();
      if (lower.contains('auth') || lower.contains('password') || lower.contains('permission denied')) {
        throw DriverException('认证失败：$msg', kind: DriverErrorKind.auth);
      }
      throw DriverException('SFTP 连接失败：$msg', kind: DriverErrorKind.network);
    }
  }

  @override
  Future<void> close() async {
    _client?.close();
    _client = null;
    _sftp = null;
  }

  SftpClient get _s {
    final s = _sftp;
    if (s == null) throw DriverException('SFTP 会话未建立', kind: DriverErrorKind.network);
    return s;
  }

  @override
  Future<List<RemoteEntry>> list(String path) async {
    final target = normalizePath(path);
    try {
      final items = await _s.listdir(target);
      final entries = <RemoteEntry>[];
      for (final item in items) {
        final name = item.filename;
        if (name == '.' || name == '..' || name.isEmpty) continue;
        final dynamic attr = item.attr;
        final dynamic rawDir = attr.isDirectory;
        final dynamic rawSize = attr.size;
        final isDir = rawDir == true;
        entries.add(RemoteEntry(
          name: name,
          path: joinPath(target, name),
          isDir: isDir,
          size: isDir ? 0 : (rawSize is int ? rawSize : 0),
          modified: _mtime(attr),
        ));
      }
      entries.sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      return entries;
    } catch (e) {
      throw DriverException('SFTP 列目录失败：$e', kind: DriverErrorKind.network);
    }
  }

  DateTime? _mtime(dynamic attr) {
    try {
      final dynamic v = attr.modifyTime;
      if (v is DateTime) return v;
      if (v is int) return DateTime.fromMillisecondsSinceEpoch(v * 1000);
    } catch (_) {}
    return null;
  }

  @override
  Future<SpaceInfo?> space() async => null;

  @override
  Future<Uint8List> readAll(String path) async {
    final file = await _s.open(normalizePath(path));
    try {
      return await file.readBytes();
    } finally {
      await file.close();
    }
  }

  @override
  Future<void> downloadTo(String remotePath, String localFile, {ProgressFn? onProgress}) async {
    final target = normalizePath(remotePath);
    final stat = await _s.stat(target);
    final total = stat.size ?? 0;
    if (total > _memoryLimit) {
      throw DriverException('超过 64 MB 的 SFTP 下载将在下一阶段支持流式传输',
          kind: DriverErrorKind.unsupported);
    }
    final bytes = await readAll(target);
    final sink = File(localFile).openWrite();
    try {
      sink.add(bytes);
      onProgress?.call(bytes.length, total);
    } finally {
      await sink.close();
    }
  }

  @override
  Future<void> uploadFile(String localFile, String remotePath, {ProgressFn? onProgress}) async {
    final file = File(localFile);
    final length = await file.length();
    if (length > _memoryLimit) {
      throw DriverException('超过 64 MB 的 SFTP 上传将在下一阶段支持流式传输',
          kind: DriverErrorKind.unsupported);
    }
    final bytes = await file.readAsBytes();
    final target = normalizePath(remotePath);
    final handle = await _s.open(
      target,
      mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate,
    );
    try {
      await handle.writeBytes(bytes);
      onProgress?.call(bytes.length, length);
    } finally {
      await handle.close();
    }
  }

  @override
  Future<void> mkdir(String path) async {
    await _s.mkdir(normalizePath(path));
  }

  @override
  Future<void> removeEntry(RemoteEntry entry) async {
    if (entry.isDir) {
      await _s.rmdir(normalizePath(entry.path));
    } else {
      await _s.remove(normalizePath(entry.path));
    }
  }

  @override
  Future<void> move(String from, String to) async {
    await _s.rename(normalizePath(from), normalizePath(to));
  }

  @override
  Future<int> probe() async {
    final items = await list('/');
    return items.length;
  }
}
