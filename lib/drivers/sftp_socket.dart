import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../core/models.dart';
import 'net.dart';

/// 让 SSH 会话跑在代理隧道上。
///
/// `SSHSocket.connect` 走系统原生 socket，无法经过代理；这里把
/// [ProxyTunnel] 建立好的隧道包装成 dartssh2 需要的 [SSHSocket]。
/// 握手（HTTP CONNECT / SOCKS5）在隧道建立阶段就已完成，之后
/// 交给 SSH 层的就是一条干净的字节流。
class ProxySshSocket implements SSHSocket {
  ProxySshSocket._(this._socket);

  final Socket _socket;

  static Future<SSHSocket> connect(
    String host,
    int port,
    ProxyConfig proxy, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final socket = await ProxyTunnel.connect(host, port, proxy, timeout: timeout);
    return ProxySshSocket._(socket);
  }

  @override
  Future<void> get done => _socket.done;

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  Stream<Uint8List> get stream => _socket;

  @override
  Future<void> close() => _socket.close();

  @override
  void destroy() => _socket.destroy();

  @override
  Future<void> flush() => _socket.flush();
}
