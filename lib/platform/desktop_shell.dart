import 'dart:async';
import 'dart:io';
import 'dart:ui' show Size;

import 'package:tray_manager/legacy.dart';
import 'package:tray_manager/tray_manager.dart'
    show TrayIconDoubleClickedEvent;
import 'package:window_manager/window_manager.dart';

import '../core/store.dart';

/// Windows 桌面外壳：托盘图标、右键菜单、主窗口显隐、关窗行为。
///
/// 交互约定：
/// - 左键单击：无反应
/// - 左键双击：显示并聚焦主窗口
/// - 右键：菜单（显示主窗口 / 退出）
/// - 点窗口 ×：按设置「收进托盘」或直接退出（`setPreventClose(true)` 后
///   由 [onWindowClose] 接管，否则根窗口会被直接销毁，托盘就点了也没用）
class DesktopShell with TrayListener, WindowListener {
  DesktopShell._();

  static final DesktopShell instance = DesktopShell._();

  bool _ready = false;
  DateTime? _lastClickAt;

  Future<void> init() async {
    if (!Platform.isWindows || _ready) return;
    _ready = true;
    try {
      await windowManager.ensureInitialized();
      await _applyWindowChrome();
      windowManager.addListener(this);
      // 必须先打开拦截，否则窗口关闭时控件被销毁，托盘菜单就无效了。
      await windowManager.setPreventClose(true);
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

  /// 首次启动的窗口尺寸：太小的默认窗口装不下三栏布局，先给个下限。
  Future<void> _applyWindowChrome() async {
    try {
      await windowManager.setTitle('Nimbo');
      await windowManager.setMinimumSize(const Size(940, 620));
      final size = await windowManager.getSize();
      if (size.width < 940 || size.height < 620) {
        await windowManager.setSize(const Size(1180, 780));
        await windowManager.center();
      }
    } catch (_) {}
  }

  Future<void> showWindow() async {
    if (!Platform.isWindows) return;
    try {
      await windowManager.show();
      await windowManager.restore();
      await windowManager.focus();
    } catch (_) {}
  }

  Future<void> hideWindow() async {
    if (!Platform.isWindows) return;
    try {
      await windowManager.hide();
    } catch (_) {}
  }

  Future<void> exitApp() async {
    try {
      await trayManager.destroy();
    } catch (_) {}
    try {
      await windowManager.setPreventClose(false);
    } catch (_) {}
    exit(0);
  }

  // ---------- WindowListener ----------

  @override
  void onWindowClose() {
    // setPreventClose(true) 之后系统不再销毁窗口，行为完全由这里决定。
    if (Prefs.instance.settings.closeToTray) {
      unawaited(hideWindow());
    } else {
      unawaited(exitApp());
    }
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
