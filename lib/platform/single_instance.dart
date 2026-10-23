import 'dart:async';
import 'dart:io';

const int _kInstancePort = 47913;

/// Windows 单实例保护。
///
/// 首个进程占用回环端口；后续进程连上后通知已有实例显示窗口，然后自行退出。
/// 不依赖第三方包，也不会在异常退出时留下锁文件（端口随进程释放）。
Future<bool> acquireSingleInstance(Future<void> Function() onSecondLaunch) async {
  if (!Platform.isWindows) return true;
  try {
    final server =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, _kInstancePort);
    server.listen((socket) {
      socket.destroy();
      unawaited(onSecondLaunch());
    });
    return true;
  } on SocketException {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        _kInstancePort,
        timeout: const Duration(seconds: 2),
      );
      socket.write('show');
      await socket.flush();
      socket.destroy();
    } catch (_) {
      // 端口被别的程序占用：仍然退出，避免出现两个实例
    }
    return false;
  }
}
