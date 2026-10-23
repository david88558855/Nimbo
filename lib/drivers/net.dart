import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/models.dart';
import 'storage_driver.dart';

/// 代理连接层：HTTP CONNECT 隧道 + SOCKS5 握手。
/// 代理是挂载的属性，这里只负责"为这个挂载开一条隧道"，不读系统代理。
class ProxyTunnel {
  static Future<Socket> connect(
    String host,
    int port,
    ProxyConfig proxy, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final raw = await Socket.connect(proxy.host, proxy.port, timeout: timeout);
    raw.setOption(SocketOption.tcpNoDelay, true);

    final controller = StreamController<Uint8List>(sync: true);
    final done = Completer<void>();
    final buf = <int>[];
    var pos = 0;
    var step = 0;
    var passthrough = false;
    final isHttp = proxy.type == ProxyType.http;

    void finish() {
      if (done.isCompleted) return;
      passthrough = true;
      if (buf.length > pos) controller.add(Uint8List.fromList(buf.sublist(pos)));
      buf.clear();
      pos = 0;
      done.complete();
    }

    void fail(Object e) {
      if (!done.isCompleted) done.completeError(e);
    }

    void sendConnect() {
      final hostBytes = utf8.encode(host);
      final isIp = InternetAddress.tryParse(host) != null;
      final addr = isIp
          ? <int>[0x01, ...InternetAddress(host).rawAddress]
          : <int>[0x03, hostBytes.length, ...hostBytes];
      raw.add(Uint8List.fromList([0x05, 0x01, 0x00, ...addr, (port >> 8) & 0xFF, port & 0xFF]));
      raw.flush();
      step = 2;
    }

    void advance() {
      if (isHttp) {
        // 等 \r\n\r\n
        for (var i = 0; i + 3 < buf.length; i++) {
          if (buf[i] == 13 && buf[i + 1] == 10 && buf[i + 2] == 13 && buf[i + 3] == 10) {
            final head = utf8.decode(buf.sublist(0, i), allowMalformed: true);
            final line = head.split('\r\n').first;
            final parts = line.split(' ');
            final code = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
            if (code != 200) {
              fail(DriverException(
                code == 407 ? '代理要求认证（407），请填写代理账号密码' : '代理拒绝建立隧道：$line',
                kind: DriverErrorKind.proxy,
              ));
              return;
            }
            pos = i + 4;
            finish();
            return;
          }
        }
        return;
      }

      // SOCKS5 状态机
      if (step == 0) {
        if (buf.length < 2) return;
        if (buf[0] != 0x05) {
          fail(DriverException('SOCKS5 握手失败：版本号异常', kind: DriverErrorKind.proxy));
          return;
        }
        final method = buf[1];
        pos = 2;
        if (method == 0xFF) {
          fail(DriverException('SOCKS5 代理不接受当前认证方式', kind: DriverErrorKind.proxy));
          return;
        }
        if (method == 0x02) {
          final u = utf8.encode(proxy.username);
          final p = utf8.encode(proxy.password);
          raw.add(Uint8List.fromList([0x01, u.length, ...u, p.length, ...p]));
          raw.flush();
          step = 1;
        } else {
          sendConnect();
        }
        advance();
        return;
      }

      if (step == 1) {
        if (buf.length - pos < 2) return;
        if (buf[pos + 1] != 0x00) {
          fail(DriverException('SOCKS5 用户名或密码被拒绝', kind: DriverErrorKind.auth));
          return;
        }
        pos += 2;
        sendConnect();
        advance();
        return;
      }

      if (step == 2) {
        if (buf.length - pos < 4) return;
        if (buf[pos + 1] != 0x00) {
          fail(DriverException('SOCKS5 无法连接目标（错误码 ${buf[pos + 1]}）', kind: DriverErrorKind.network));
          return;
        }
        final atyp = buf[pos + 3];
        pos += 4;
        if (atyp == 0x01) {
          if (buf.length - pos < 6) return;
          pos += 6;
          finish();
        } else if (atyp == 0x04) {
          if (buf.length - pos < 18) return;
          pos += 18;
          finish();
        } else {
          if (buf.length - pos < 1) return;
          final len = buf[pos];
          if (buf.length - pos < len + 3) return;
          pos += len + 3;
          finish();
        }
      }
    }

    final sub = raw.listen((data) {
      if (passthrough) {
        controller.add(data);
        return;
      }
      buf.addAll(data);
      try {
        advance();
      } catch (e) {
        fail(e);
      }
    }, onError: (Object e) {
      if (!done.isCompleted) fail(DriverException('代理连接中断：$e', kind: DriverErrorKind.proxy));
      controller.addError(e);
    }, onDone: () {
      if (!done.isCompleted) fail(DriverException('代理提前关闭了连接', kind: DriverErrorKind.proxy));
      controller.close();
    });

    try {
      if (isHttp) {
        final auth = proxy.username.isEmpty
            ? ''
            : 'Proxy-Authorization: Basic ${base64Encode(utf8.encode('${proxy.username}:${proxy.password}'))}\r\n';
        raw.write('CONNECT $host:$port HTTP/1.1\r\n'
            'Host: $host:$port\r\n'
            '$auth'
            'Proxy-Connection: Keep-Alive\r\n\r\n');
        await raw.flush();
      } else {
        final useAuth = proxy.username.isNotEmpty;
        raw.add(Uint8List.fromList([0x05, 0x01, useAuth ? 0x02 : 0x00]));
        await raw.flush();
      }
      await done.future.timeout(timeout,
          onTimeout: () => throw DriverException('代理响应超时', kind: DriverErrorKind.proxy));
    } catch (e) {
      await sub.cancel();
      raw.destroy();
      if (e is DriverException) rethrow;
      throw DriverException('代理连接失败：$e', kind: DriverErrorKind.proxy);
    }

    return TunnelSocket(raw, controller, sub);
  }
}

/// 把已建立的底层 Socket 包装成可继续使用的 Socket（握手期间的字节已剥离）。
class TunnelSocket extends Stream<Uint8List> implements Socket {
  TunnelSocket(this._inner, this._controller, this._subscription);

  final Socket _inner;
  final StreamController<Uint8List> _controller;
  final StreamSubscription<Uint8List> _subscription;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      _controller.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  InternetAddress get address => _inner.address;
  @override
  int get port => _inner.port;
  @override
  InternetAddress get remoteAddress => _inner.remoteAddress;
  @override
  int get remotePort => _inner.remotePort;

  @override
  void destroy() {
    _inner.destroy();
    if (!_controller.isClosed) _controller.close();
  }

  @override
  Future<void> close() async {
    await _subscription.cancel();
    await _inner.close();
    if (!_controller.isClosed) await _controller.close();
  }

  @override
  bool setOption(SocketOption option, bool enabled) => _inner.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) => _inner.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => _inner.setRawOption(option);

  @override
  Encoding get encoding => _inner.encoding;
  @override
  set encoding(Encoding value) => _inner.encoding = value;

  @override
  void add(List<int> data) => _inner.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) => _inner.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<List<int>> stream) => _inner.addStream(stream);
  @override
  Future<void> flush() => _inner.flush();
  @override
  void write(Object? object) => _inner.write(object);
  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) => _inner.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _inner.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => _inner.writeln(object);
  @override
  Future<void> get done => _inner.done;
}

/// 为 dio 构造带代理的 HttpClient。
/// HTTP 代理用系统原生 findProxy（自动对 https 发 CONNECT，兼容性最好）；
/// SOCKS5 无原生支持，用 connectionFactory 直接交出隧道 Socket。
HttpClient buildHttpClient(ProxyConfig? proxy) {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..idleTimeout = const Duration(seconds: 15)
    ..userAgent = 'Nimbo/0.1';

  final p = proxy;
  if (p == null || !p.enabled) return client;

  if (p.type == ProxyType.http) {
    client.findProxy = (uri) => 'PROXY ${p.host}:${p.port}';
    if (p.username.isNotEmpty) {
      client.addProxyCredentials(
        p.host,
        p.port,
        'Basic',
        HttpClientBasicCredentials(p.username, p.password),
      );
    }
  } else {
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      // ConnectionTask.fromSocket 接收 Future<Socket>，隧道建立与握手都在其中完成
      return ConnectionTask.fromSocket(
        ProxyTunnel.connect(uri.host, uri.port, p),
        () {},
      );
    };
  }
  return client;
}
