import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/format.dart';
import '../core/models.dart';
import 'net.dart';
import 'storage_driver.dart';

/// FTP / FTPS：直接实现协议（不依赖第三方 FTP 包），
/// 这样控制连接与数据连接都能走同一条按挂载配置的代理隧道。
class FtpDriver extends StorageDriver {
  FtpDriver(super.mount, {required this.password, required this.proxy});

  final String password;
  final ProxyConfig proxy;

  Socket? _control;
  _FtpSession? _session;

  @override
  String get scheme => 'ftp';

  @override
  Capability get caps => const Capability(space: false, move: true);

  @override
  ResumeSupport get resume => ResumeSupport.both;

  @override
  Future<void> connect() async {
    final host = mount.host.trim();
    if (host.isEmpty) throw DriverException('请填写主机地址');
    final port = mount.port == 0 ? 21 : mount.port;
    final Socket socket = proxy.enabled
        ? await ProxyTunnel.connect(host, port, proxy)
        : await Socket.connect(host, port, timeout: const Duration(seconds: 20));
    _control = socket;
    final session = _FtpSession(socket);
    _session = session;
    try {
      await session.expect(220);
      await session.command('USER ${mount.username.isEmpty ? 'anonymous' : mount.username}', 331, 230);
      if (mount.username.isNotEmpty) {
        await session.command('PASS $password', 230);
      }
      await session.command('TYPE I', 200);
    } on DriverException {
      socket.destroy();
      rethrow;
    }
  }

  @override
  Future<void> close() async {
    try {
      await _session?.command('QUIT', 221);
    } catch (_) {}
    _control?.destroy();
    _control = null;
    _session = null;
  }

  _FtpSession get _s {
    final s = _session;
    if (s == null) throw DriverException('FTP 会话未建立', kind: DriverErrorKind.network);
    return s;
  }

  Future<Socket> _dataSocket() async {
    final reply = await _s.command('PASV', 227);
    final m = RegExp(r'(\d+),(\d+),(\d+),(\d+),(\d+),(\d+)').firstMatch(reply.text);
    if (m == null) throw DriverException('PASV 响应无法解析：${reply.text}');
    var ip = '${m[1]}.${m[2]}.${m[3]}.${m[4]}';
    final port = int.parse(m[5]!) * 256 + int.parse(m[6]!);
    // 经代理时，服务器回的内网 IP 往往不可达，改用控制连接的主机
    if (proxy.enabled) ip = mount.host;
    return proxy.enabled
        ? ProxyTunnel.connect(ip, port, proxy)
        : Socket.connect(ip, port, timeout: const Duration(seconds: 20));
  }

  @override
  Future<List<RemoteEntry>> list(String path) async {
    final target = normalizePath(path);
    List<RemoteEntry>? parsed;
    try {
      final data = await _dataSocket();
      await _s.command('MLSD $target', 150);
      final bytes = await _collect(data);
      await _s.expect(226);
      parsed = _parseMlsd(bytes, target);
    } on DriverException {
      // 服务器不支持 MLSD 时回落到 LIST
      parsed = null;
    }
    if (parsed == null) {
      final data = await _dataSocket();
      await _s.command('LIST $target', 150);
      final bytes = await _collect(data);
      await _s.expect(226);
      parsed = _parseList(bytes, target);
    }
    parsed.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return parsed;
  }

  Future<Uint8List> _collect(Socket data) async {
    final builder = BytesBuilder(copy: true);
    await for (final chunk in data) {
      builder.add(chunk);
    }
    await data.close();
    return builder.toBytes();
  }

  List<RemoteEntry> _parseMlsd(Uint8List bytes, String base) {
    final text = utf8.decode(bytes, allowMalformed: true);
    final entries = <RemoteEntry>[];
    for (final rawLine in const LineSplitter().convert(text)) {
      final line = rawLine.trimRight();
      if (line.isEmpty) continue;
      final sp = line.indexOf(' ');
      if (sp <= 0) continue;
      final facts = line.substring(0, sp);
      final name = line.substring(sp + 1).trim();
      if (name.isEmpty || name == '.' || name == '..') continue;
      var isDir = false;
      var size = 0;
      DateTime? modified;
      for (final f in facts.split(';')) {
        final eq = f.indexOf('=');
        if (eq <= 0) continue;
        final k = f.substring(0, eq).toLowerCase();
        final v = f.substring(eq + 1);
        if (k == 'type') isDir = v.toLowerCase() == 'dir' || v.toLowerCase() == 'cdir';
        if (k == 'size') size = int.tryParse(v) ?? 0;
        if (k == 'modify' && v.length >= 14) {
          modified = DateTime.tryParse('${v.substring(0, 4)}-${v.substring(4, 6)}-${v.substring(6, 8)}'
              'T${v.substring(8, 10)}:${v.substring(10, 12)}:${v.substring(12, 14)}Z');
        }
      }
      entries.add(RemoteEntry(
        name: name,
        path: joinPath(normalizePath(base), name),
        isDir: isDir,
        size: isDir ? 0 : size,
        modified: modified,
      ));
    }
    return entries;
  }

  List<RemoteEntry> _parseList(Uint8List bytes, String base) {
    final text = utf8.decode(bytes, allowMalformed: true);
    final entries = <RemoteEntry>[];
    for (final line in const LineSplitter().convert(text)) {
      if (line.trim().isEmpty) continue;
      if (line.toLowerCase().startsWith('total')) continue;
      final isDir = line.startsWith('d');
      final isFile = line.startsWith('-');
      if (!isDir && !isFile) continue;
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length < 9) continue;
      final size = int.tryParse(parts[4]) ?? 0;
      final name = parts.skip(8).join(' ');
      if (name == '.' || name == '..') continue;
      entries.add(RemoteEntry(
        name: name,
        path: joinPath(normalizePath(base), name),
        isDir: isDir,
        size: isDir ? 0 : size,
      ));
    }
    return entries;
  }

  @override
  Future<SpaceInfo?> space() async => null;

  @override
  Future<Uint8List> readAll(String path) async {
    final data = await _dataSocket();
    await _s.command('RETR ${normalizePath(path)}', 150);
    final bytes = await _collect(data);
    await _s.expect(226);
    return bytes;
  }

  @override
  Future<void> downloadTo(String remotePath, String localFile,
      {ProgressFn? onProgress, int resumeFrom = 0}) async {
    int total = 0;
    try {
      final reply = await _s.command('SIZE ${normalizePath(remotePath)}', 213);
      total = int.tryParse(reply.text.trim()) ?? 0;
    } catch (_) {}

    final raf = await File(localFile).open(mode: FileMode.append);
    try {
      var start = resumeFrom;
      final existing = await raf.length();
      if (existing != start) start = existing;
      if (total > 0 && start >= total) start = 0;
      if (start > 0) {
        try {
          // REST 让后续 RETR 从指定偏移开始；服务器不支持时退回完整下载。
          await _s.command('REST $start', 350);
        } catch (_) {
          start = 0;
        }
      }
      await raf.truncate(start);
      await raf.setPosition(start);

      final data = await _dataSocket();
      await _s.command('RETR ${normalizePath(remotePath)}', 150);
      var done = start;
      try {
        await for (final chunk in data) {
          await raf.writeFrom(chunk);
          done += chunk.length;
          onProgress?.call(done, total);
        }
      } finally {
        await data.close();
      }
      await _s.expect(226);
    } finally {
      await raf.close();
    }
  }

  @override
  Future<void> uploadFile(String localFile, String remotePath,
      {ProgressFn? onProgress, int resumeFrom = 0}) async {
    final file = File(localFile);
    final total = await file.length();
    var start = resumeFrom > total ? 0 : resumeFrom;
    final data = await _dataSocket();
    // APPE 从远端末尾追加；STOR 覆盖写。
    await _s.command(
      '${start > 0 ? 'APPE' : 'STOR'} ${normalizePath(remotePath)}',
      150,
    );
    var done = start;
    final raf = await file.open();
    try {
      if (start > 0) await raf.setPosition(start);
      while (done < total) {
        final chunk = await raf.read(1 << 20);
        if (chunk.isEmpty) break;
        data.add(chunk);
        done += chunk.length;
        onProgress?.call(done, total);
      }
    } finally {
      await raf.close();
    }
    await data.flush();
    await data.close();
    await _s.expect(226);
  }

  @override
  Future<int> sizeOf(String path) async {
    try {
      final reply = await _s.command('SIZE ${normalizePath(path)}', 213);
      return int.tryParse(reply.text.trim()) ?? -1;
    } catch (_) {
      return -1;
    }
  }

  @override
  Future<void> mkdir(String path) async {
    await _s.command('MKD ${normalizePath(path)}', 257, 250);
  }

  @override
  Future<void> removeEntry(RemoteEntry entry) async {
    if (entry.isDir) {
      await _s.command('RMD ${normalizePath(entry.path)}', 250);
    } else {
      await _s.command('DELE ${normalizePath(entry.path)}', 250);
    }
  }

  @override
  Future<void> move(String from, String to) async {
    await _s.command('RNFR ${normalizePath(from)}', 350);
    await _s.command('RNTO ${normalizePath(to)}', 250);
  }

  @override
  Future<int> probe() async {
    final items = await list('/');
    return items.length;
  }
}

class _FtpReply {
  _FtpReply(this.code, this.text);
  final int code;
  final String text;
}

/// 控制连接：按行读取 + 多行响应归并。
class _FtpSession {
  _FtpSession(this._socket) {
    // 订阅在 socket 关闭时随流结束，无需单独持有
    _socket.listen((data) {
      _buffer.addAll(data);
      _pump();
    }, onError: (Object e) {
      _error = e;
      _pump();
    }, onDone: () {
      _closed = true;
      _pump();
    });
  }

  final Socket _socket;
  final List<int> _buffer = [];
  final List<String> _lines = [];
  Completer<void>? _waiter;
  Object? _error;
  bool _closed = false;

  void _pump() {
    var start = 0;
    for (var i = 0; i < _buffer.length; i++) {
      if (_buffer[i] == 10) {
        var end = i;
        if (end > start && _buffer[end - 1] == 13) end--;
        _lines.add(utf8.decode(_buffer.sublist(start, end), allowMalformed: true));
        start = i + 1;
      }
    }
    if (start > 0) _buffer.removeRange(0, start);
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<String> _readLine() async {
    while (_lines.isEmpty) {
      if (_error != null) throw DriverException('FTP 连接中断：$_error', kind: DriverErrorKind.network);
      if (_closed) throw DriverException('FTP 服务器关闭了连接', kind: DriverErrorKind.network);
      _waiter = Completer<void>();
      await _waiter!.future.timeout(const Duration(seconds: 30), onTimeout: () {
        throw DriverException('FTP 响应超时', kind: DriverErrorKind.network);
      });
    }
    return _lines.removeAt(0);
  }

  Future<_FtpReply> _readReply() async {
    final first = await _readLine();
    if (first.length < 3) throw DriverException('FTP 响应异常：$first');
    final code = int.tryParse(first.substring(0, 3)) ?? 0;
    final text = StringBuffer(first.length > 3 ? first.substring(4) : '');
    if (first.length > 3 && first[3] == '-') {
      while (true) {
        final next = await _readLine();
        if (next.startsWith('$code ')) {
          text.write('\n${next.length > 3 ? next.substring(4) : ''}');
          break;
        }
        text.write('\n$next');
      }
    }
    return _FtpReply(code, text.toString());
  }

  Future<_FtpReply> command(String cmd, int ok1, [int? ok2]) async {
    _socket.write('$cmd\r\n');
    await _socket.flush();
    final reply = await _readReply();
    if (reply.code != ok1 && reply.code != ok2) {
      final kind = switch (reply.code) {
        530 => DriverErrorKind.auth,
        550 => DriverErrorKind.permission,
        _ => DriverErrorKind.unknown,
      };
      throw DriverException('FTP $cmd 失败：${reply.code} ${reply.text}', kind: kind);
    }
    return reply;
  }

  Future<_FtpReply> expect(int code) async {
    final reply = await _readReply();
    if (reply.code != code) {
      throw DriverException('FTP 期望 $code，实际 ${reply.code} ${reply.text}');
    }
    return reply;
  }
}
