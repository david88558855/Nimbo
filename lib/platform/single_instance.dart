import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 单实例保护使用的回环端口区间：从 [kInstanceBasePort] 起最多试 [kInstancePortSpan] 个。
///
/// 用区间而不是单个端口，是为了处理「47913 被别的程序占着」的情况：
/// 固定端口 + 绑定失败就退出，会让用户双击 exe 什么都不发生（进程静默 exit），
/// 比多开一个实例更难排查。
const int kInstanceBasePort = 47913;
const int kInstancePortSpan = 10;

/// 第二实例 → 第一实例的请求：把已有窗口叫到前台。
const String kInstanceShow = 'nimbo:show';

/// 第一实例的应答标记：有它才能确认端口后面坐的是 Nimbo，
/// 而不是恰好占用同一端口的其它程序。
const String kInstanceAnswer = 'nimbo';

/// Windows 单实例保护。
///
/// 流程：
/// 1. 先在端口区间里逐个握手，认领到已经在运行的 Nimbo → 请它显示窗口，本进程退出；
/// 2. 没有已运行实例 → 绑定区间内第一个空闲端口，成为「第一实例」；
/// 3. 整段端口都被别的程序占用 → 放弃保护但仍然启动（不能因为端口冲突打不开程序）。
Future<bool> acquireSingleInstance(Future<void> Function() onSecondLaunch) async {
  if (!Platform.isWindows) return true;

  // 1) 先找已运行的实例。
  for (var port = kInstanceBasePort; port < kInstanceBasePort + kInstancePortSpan; port++) {
    if (await _wakeExisting(port)) return false;
  }

  // 2) 自己占一个端口并开始监听。
  for (var port = kInstanceBasePort; port < kInstanceBasePort + kInstancePortSpan; port++) {
    try {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      server.listen((socket) => _serveSecondInstance(socket, onSecondLaunch));
      return true;
    } on SocketException {
      continue; // 被占用（或残留），换下一个
    }
  }

  // 3) 区间内没有可用端口：宁可少一层保护，也不要让用户打不开程序。
  return true;
}

/// 连上 [port] 请求显示窗口；只有回包是 [kInstanceAnswer] 才算「这是 Nimbo」。
///
/// 超时给得很短：回环连接 + 一次读行，正常是毫秒级；端口上没人监听时 connect 会立刻失败。
Future<bool> _wakeExisting(int port) async {
  Socket? socket;
  try {
    socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: const Duration(milliseconds: 300),
    );
    socket.write('$kInstanceShow\n');
    await socket.flush();
    // 只等第一段文本：应答就 5 个字节，用 LineSplitter 反而要多担一层类型细节。
    final reply = await socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .first
        .timeout(const Duration(milliseconds: 500));
    return reply.trim() == kInstanceAnswer;
  } catch (_) {
    // 端口没人监听 / 不是 Nimbo / 超时：都当作「没有已运行实例」
    return false;
  } finally {
    socket?.destroy();
  }
}

/// 第一实例侧：收到握手就回标记，并请 UI 把窗口显示出来。
void _serveSecondInstance(Socket socket, Future<void> Function() onSecondLaunch) {
  var handled = false;
  late final StreamSubscription<String> sub;

  Future<void> handle(String chunk, StreamSubscription<String> self) async {
    if (handled) return;
    if (!chunk.contains(kInstanceShow)) return; // 不是我们的握手，忽略
    handled = true;
    try {
      socket.write('$kInstanceAnswer\n');
      await socket.flush();
    } catch (_) {
      // 第二实例可能已经断开，不影响唤醒
    }
    unawaited(onSecondLaunch());
    await self.cancel();
    socket.destroy();
  }

  socket.setOption(SocketOption.tcpNoDelay, true);
  sub = socket.cast<List<int>>().transform(utf8.decoder).listen(
    (chunk) => unawaited(handle(chunk, sub)),
    onError: (_) => socket.destroy(),
    onDone: () => socket.destroy(),
    cancelOnError: true,
  );
}
