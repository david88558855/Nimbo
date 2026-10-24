import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:tray_manager/legacy.dart';
import 'package:tray_manager/tray_manager.dart' show TrayIconDoubleClickedEvent;
import 'package:window_manager/window_manager.dart';

import '../core/store.dart';

/// Windows 桌面外壳：托盘图标、右键菜单、主窗口显隐、关窗行为。
///
/// 交互约定：
/// - 左键单击：无反应
/// - 左键双击：显示并聚焦主窗口
/// - 右键：菜单「显示主窗口 / 退出」
/// - 点窗口 ×：收进托盘（默认）；托盘不可用、或用户关掉该设置时直接退出
///
/// 三个容易踩的点（都在这份实现里处理）：
/// 1. `setPreventClose(true)` 之后必须自己处理 [onWindowClose]，否则窗口控件被销毁，
///    托盘还在但点了没反应；
/// 2. 菜单点击会被 `tray_manager` 派发两次（`MenuItem.onClick` 与
///    `TrayListener.onTrayMenuItemClick` 各一次），退出必须幂等；
/// 3. 托盘初始化失败时绝不能「收进托盘」——窗口隐藏后没有任何入口能叫回来。
class DesktopShell with TrayListener, WindowListener {
  DesktopShell._();

  static final DesktopShell instance = DesktopShell._();

  bool _initStarted = false;

  /// 托盘图标 + 右键菜单都就绪后才为 true；关窗行为据此决定 hide 还是退出。
  bool _trayReady = false;

  /// 退出流程只跑一次（菜单点击会触发两次，见类注释第 2 条）。
  bool _exiting = false;

  DateTime? _lastClickAt;
  DateTime? _lastShowAt;

  /// 退出前的收尾（落盘配置与传输记录）。由 `main.dart` 注入，
  /// 避免 platform 层反向依赖 state 层。
  Future<void> Function()? onBeforeExit;

  Future<void> init() async {
    if (!Platform.isWindows || _initStarted) return;
    _initStarted = true;
    try {
      await windowManager.ensureInitialized();
      await _applyWindowChrome();
      windowManager.addListener(this);
      // 必须先打开拦截，否则窗口关闭时控件被销毁，托盘菜单就无效了。
      await windowManager.setPreventClose(true);
      trayManager.addListener(this);
      await _installTrayIcon();
      try {
        await trayManager.setToolTip('Nimbo');
      } catch (_) {
        // 提示文字失败无关紧要，别让它挡住后面的右键菜单
      }
      // 右键菜单是「退出」的唯一入口，装不上就等于托盘不可用。
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: '显示主窗口', onClick: (_) => showWindow()),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: '退出', onClick: (_) => exitApp()),
      ]));
      try {
        // 0.5.x 兼容层会忽略 DoubleClicked 事件（`_wireTrayEvents` 里直接 break），
        // 这里直接挂到底层图标上兜底；挂不上也不影响菜单。
        trayManager.trayIcon?.addListener((event) {
          if (event is TrayIconDoubleClickedEvent) showWindow();
        });
      } catch (_) {}
      _trayReady = true;
    } catch (e) {
      _trayReady = false;
      debugPrint('Nimbo: 托盘初始化失败，关闭窗口将直接退出：$e');
    }
  }

  /// 托盘图标：Windows 首选 `.ico`（多尺寸、带 alpha），加载失败再退到 `.png`。
  ///
  /// 插件把资源名解析成 `<exe 目录>/data/flutter_assets/<asset>` 再读文件，
  /// 因此便携版分发时必须带上 `data/` 目录（CI 的 zip 已包含）。
  Future<void> _installTrayIcon() async {
    try {
      await trayManager.setIcon('assets/tray.ico');
    } catch (_) {
      await trayManager.setIcon('assets/tray.png');
    }
  }

  /// 首次启动的窗口尺寸：太小的默认窗口装不下三栏布局，先给个下限。
  ///
  /// 下限也要受当前屏幕约束：高 DPI 的小屏上 940×620 可能比可用区域还大，
  /// 窗口会顶出屏幕、内容被裁。
  Future<void> _applyWindowChrome() async {
    try {
      await windowManager.setTitle('Nimbo');
      var minW = 940.0;
      var minH = 620.0;
      var wantW = 1180.0;
      var wantH = 780.0;
      final view = WidgetsBinding.instance.platformDispatcher.implicitView;
      if (view != null) {
        final screen = view.physicalSize / view.devicePixelRatio;
        if (screen.width > 0 && screen.height > 0) {
          minW = math.min(minW, screen.width * 0.92);
          minH = math.min(minH, screen.height * 0.9);
          wantW = math.min(wantW, screen.width);
          wantH = math.min(wantH, screen.height);
        }
      }
      await windowManager.setMinimumSize(Size(minW, minH));
      final current = await windowManager.getSize();
      if (current.width < minW || current.height < minH) {
        await windowManager.setSize(Size(math.max(wantW, minW), math.max(wantH, minH)));
        await windowManager.center();
      }
    } catch (_) {}
  }

  Future<void> showWindow() async {
    if (!Platform.isWindows) return;
    // 双击会同时命中「时间差判定」与底层 DoubleClicked 两条路，
    // 200ms 内的重复请求直接吞掉，避免 show/restore/focus 连做两遍。
    final now = DateTime.now();
    final last = _lastShowAt;
    if (last != null && now.difference(last) < const Duration(milliseconds: 200)) return;
    _lastShowAt = now;
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

  /// 彻底退出：先落盘，再销毁托盘、解除关窗拦截，最后 exit。
  Future<void> exitApp() async {
    if (_exiting) return; // 菜单点击会触发两次，只处理第一次
    _exiting = true;
    try {
      final flush = onBeforeExit;
      // 给收尾 2 秒上限：磁盘异常时也必须能退出，不能被落盘卡死。
      if (flush != null) await flush().timeout(const Duration(seconds: 2));
    } catch (_) {}
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
    // 只有托盘真的可用时才允许「收进托盘」：否则窗口隐藏后没有任何入口能把它叫回来，
    // 进程会变成看不见也关不掉的僵尸。
    if (Prefs.instance.settings.closeToTray && _trayReady) {
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
    // 这个回调与 MenuItem.onClick 会被同时触发（见类注释第 2 条）。
    // 正常路径已由 onClick 处理，这里保持空实现，避免同一动作跑两遍；
    // 保留重写是为了说明「不是漏了它」，也便于将来插件只派发其一时切换。
  }
}
