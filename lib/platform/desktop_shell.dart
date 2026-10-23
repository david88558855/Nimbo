import 'dart:io';

import 'package:tray_manager/legacy.dart';
import 'package:tray_manager/tray_manager.dart'
    show TrayIconDoubleClickedEvent;
import 'package:window_manager/window_manager.dart';

/// Windows 桌面外壳：托盘图标、右键菜单、主窗口显隐。
///
/// 交互约定：
/// - 左键单击：无反应
/// - 左键双击：显示并聚焦主窗口
/// - 右键：菜单（显示主窗口 / 退出）
class DesktopShell with TrayListener {
  DesktopShell._();

  static final DesktopShell instance = DesktopShell._();

  bool _ready = false;
  DateTime? _lastClickAt;

  Future<void> init() async {
    if (!Platform.isWindows || _ready) return;
    _ready = true;
    try {
      await windowManager.ensureInitialized();
      trayManager.addListener(this);
      await trayManager.setIcon('assets/tray.ico');
      await trayManager.setToolTip('Nimbo');
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: '显示主窗口', onClick: (_) => showWindow()),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: '退出', onClick: (_) => exitApp()),
      ]));
      // 0.5.x 兼容层会忽略 DoubleClicked 事件，这里直接挂到底层图标上兜底。
      trayManager.trayIcon?.addListener((event) {
        if (event is TrayIconDoubleClickedEvent) showWindow();
      });
    } catch (_) {
      // 托盘不可用（系统策略禁用等）不影响主功能
    }
  }

  Future<void> showWindow() async {
    if (!Platform.isWindows) return;
    try {
      await windowManager.show();
      await windowManager.restore();
      await windowManager.focus();
    } catch (_) {}
  }

  Future<void> exitApp() async {
    try {
      await trayManager.destroy();
    } catch (_) {}
    exit(0);
  }

  // ---------- TrayListener（0.5.x 兼容层）----------

  @override
  void onTrayIconMouseDown() {
    // 单击必须无反应；系统在双击时会连发两次 down，用时间差识别。
    final now = DateTime.now();
    final last = _lastClickAt;
    _lastClickAt = now;
    if (last != null && now.difference(last) < const Duration(milliseconds: 450)) {
      _lastClickAt = null;
      showWindow();
    }
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        showWindow();
        break;
      case 'exit':
        exitApp();
        break;
      default:
        break;
    }
  }
}
