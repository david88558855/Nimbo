import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app/theme.dart';
import 'pages/shell.dart';
import 'platform/desktop_shell.dart';
import 'platform/single_instance.dart';
import 'state/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    // 单实例：第二个进程通知已有实例显示窗口后直接退出
    final first = await acquireSingleInstance(DesktopShell.instance.showWindow);
    if (!first) exit(0);
  }
  final state = AppState();
  await state.boot();
  runApp(NimboApp(state: state));
  if (Platform.isWindows) {
    // 首帧后再建托盘，确保原生窗口句柄已就绪
    WidgetsBinding.instance.addPostFrameCallback((_) {
      DesktopShell.instance.init();
    });
  }
}

class NimboApp extends StatelessWidget {
  const NimboApp({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nimbo',
      debugShowCheckedModeBanner: false,
      theme: buildNimboTheme(),
      // 整体字号：Android 上把文本缩放的「下限」抬到 kNimboMobileScale，
      // 桌面完全跟随系统。放在 builder 里是为了让对话框、SnackBar、Tooltip
      // 这些由 Navigator/Overlay 创建的内容也一起生效。
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: nimboTextScaler(context)),
        child: child ?? const SizedBox.shrink(),
      ),
      home: AnimatedBuilder(
        animation: state,
        builder: (context, _) => NimboShell(state: state),
      ),
    );
  }
}
