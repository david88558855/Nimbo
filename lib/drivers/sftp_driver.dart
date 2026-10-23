import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../core/format.dart';
import '../core/models.dart';
import 'sftp_socket.dart';
import 'storage_driver.dart';

/// SFTP：dartssh2 纯 Dart 实现。
///
/// 代理：直连走系统原生 socket，开启代理时把 [ProxyTunnel] 的隧道
/// 包成 SSHSocket 交给 SSH 层——与 FTP / HTTP 类协议共用同一套握手代码。
/// 传输：走 SftpFile 的分块读写，不再有内存上限。
class SftpDriver extends StorageDriver {
  SftpDriver(super.mount, {required this.password, required this.proxy});

  final String password;
  final ProxyConfig proxy;

  SSHClient? _client;
  SftpClient? _sftp;

  @override
  String get scheme => 'sftp';

  @override
  Capability get caps => const Capability(space: false, move: true);

  @override
  Future<void> connect() async {
    final host = mount.host.trim();
    if (host.isEmpty) throw DriverException('请填写主机地址');
    final port = mount.port == 0 ? 22 : mount.port;
    try {
      final socket = proxy.enabled
          ? await ProxySshSocket.connect(host, port, proxy)
          : await SSHSocket.connect(host, port);
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
      if (lower.contains('auth') ||
          lower.contains('password') ||
          lower.contains('permission denied')) {
        throw DriverException('认证失败：$msg', kind: DriverErrorKind.auth);
      }
      if (e is DriverException) rethrow;
      throw DriverException(
        proxy.enabled ? 'SFTP 连接失败（经代理 ${proxy.label}）：$msg' : 'SFTP 连接失败：$msg',
        kind: DriverErrorKind.network,
      );
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
    var total = 0;
    try {
      final stat = await _s.stat(target);
      total = stat.size ?? 0;
    } catch (_) {}
    final handle = await _s.open(target);
    final sink = File(localFile).openWrite();
    var done = 0;
    try {
      await for (final chunk in handle.read()) {
        sink.add(chunk);
        done += chunk.length;
        onProgress?.call(done, total > 0 ? total : done);
      }
    } finally {
      await sink.close();
      await handle.close();
    }
  }

  @override
  Future<void> uploadFile(String localFile, String remotePath, {ProgressFn? onProgress}) async {
    final file = File(localFile);
    final length = await file.length();
    final target = normalizePath(remotePath);
    final handle = await _s.open(
      target,
      mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate,
    );
    var done = 0;
    final raf = await file.open();
    try {
      // 1 MB 为一块：内存占用恒定，且天然可被进度回调中断。
      while (done < length) {
        final chunk = await raf.read(1 << 20);
        if (chunk.isEmpty) break;
        await handle.writeBytes(chunk, offset: done);
        done += chunk.length;
        onProgress?.call(done, length);
      }
    } finally {
      await raf.close();
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
