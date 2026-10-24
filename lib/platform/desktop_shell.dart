import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:tray_manager/legacy.dart';
import 'package:tray_manager/tray_manager.dart'
    show ContextMenuTrigger, TrayIconDoubleClickedEvent;
import 'package:window_manager/window_manager.dart';

import '../core/store.dart';

/// Windows 桌面外壳：托盘图标、右键菜单、主窗口显隐、关窗行为。
///
/// 交互约定：
/// - 左键单击：无任何响应（托盘图标常被误触，单击就弹窗很打扰）
/// - 左键双击：显示并聚焦主窗口 —— 与右键菜单「显示主窗口」走**同一个** [showWindow]
/// - 右键：弹出菜单「显示主窗口 / 退出」
/// - 点窗口 ×：收进托盘（默认）；托盘不可用、或用户关掉该设置时直接退出
///
/// 五个容易踩的点（都在这份实现里处理）：
/// 1. **右键菜单必须显式打开原生触发**（[ContextMenuTrigger.rightClicked]）。
///    nativeapi 的托盘 `context_menu_trigger_` 默认是 `None`：右键只发
///    `TrayIconRightClickedEvent`，不会弹菜单；而 `tray_manager` 0.8 的
///    兼容层 `setContextMenu()` 只挂菜单、**从不**设这个触发器。
///    只调 `setContextMenu()` 的结果就是「右键毫无反应」。
/// 2. `setPreventClose(true)` 之后必须自己处理 [onWindowClose]，否则窗口控件被销毁，
///    托盘还在但点了没反应；
/// 3. 菜单点击会被 `tray_manager` 派发两次（`MenuItem.onClick` 与
///    `TrayListener.onTrayMenuItemClick` 各一次），退出必须幂等；
/// 4. 托盘初始化失败时绝不能「收进托盘」——窗口隐藏后没有任何入口能叫回来；
/// 5. 菜单点击回调是在原生 `TrackPopupMenu` 的调用栈里派发的（插件用
///    `TPM_RETURNCMD` 保证这一点），此时立刻 `trayManager.destroy()` 会把菜单对象
///    从正在执行的 `Menu::Open()` 底下释放掉（use-after-free）。所以退出要先让出
///    一小段时间再销毁。
class DesktopShell with TrayListener, WindowListener {
  DesktopShell._();

  static final DesktopShell instance = DesktopShell._();

  bool _initStarted = false;

  /// 托盘图标 + 右键菜单都就绪后才为 true；关窗行为据此决定 hide 还是退出。
  bool _trayReady = false;

  /// 原生「右键自动弹菜单」是否真的生效。
  ///
  /// 为 false 时 [onTrayIconRightMouseDown] 会手动 `popUpContextMenu()` 兜底；
  /// 为 true 时那个回调必须是空的，否则会弹两次（第二次会立刻把第一次关掉）。
  bool _menuByNativeTrigger = false;

  /// 退出流程只跑一次（菜单点击会触发两次，见类注释第 3 条）。
  bool _exiting = false;

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
        // 与左键双击共用 [showWindow]：两条入口一套逻辑，不会有「双击能显示、
        // 菜单有时不显示」这种分叉。
        MenuItem(key: 'show', label: '显示主窗口', onClick: (_) => showWindow()),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: '退出', onClick: (_) => exitApp()),
      ]));
      // 光挂菜单不够：原生默认不显示。见类注释第 1 条。
      _menuByNativeTrigger = await _enableRightClickMenu();
      try {
        // 双击的**唯一**入口：0.5.x 兼容层会丢弃 DoubleClicked（`_wireTrayEvents`
        // 里直接 break），只能挂到底层图标上。单击不再参与任何判定。
        trayManager.trayIcon?.addListener((event) {
          if (event is TrayIconDoubleClickedEvent) showWindow();
        });
      } catch (_) {}
      _trayReady = true;
      debugPrint(
        'Nimbo: 托盘就绪（右键菜单触发方式：'
        '${_menuByNativeTrigger ? '原生' : '手动兜底'}）',
      );
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

  /// 打开原生的「右键自动弹菜单」开关，并读回确认已经生效。
  ///
  /// 读回是必要的：`setContextMenuTrigger` 在极老的 nativeapi 上会静默无效，
  /// 那时读回仍然是 `none`，只有靠它才能发现「设过了但没用」，从而走兜底。
  Future<bool> _enableRightClickMenu() async {
    final icon = trayManager.trayIcon;
    if (icon == null) {
      debugPrint('Nimbo: 托盘图标不存在，无法设置右键菜单触发器');
      return false;
    }
    try {
      icon.setContextMenuTrigger(ContextMenuTrigger.rightClicked);
      return icon.getContextMenuTrigger() == ContextMenuTrigger.rightClicked;
    } catch (e) {
      debugPrint('Nimbo: 原生右键触发设置失败，改用手动弹出：$e');
      return false;
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

  /// 显示并聚焦主窗口：**托盘双击**、**右键菜单「显示主窗口」**、**第二实例唤醒**
  /// 三条入口共用这一套逻辑（show → restore → focus），行为完全一致。
  ///
  /// 300ms 去重是给「双击触发两次 / 菜单被连点」兜底的：窗口已经在动的时候
  /// 再跑一遍 show/restore/focus 会闪。
  Future<void> showWindow() async {
    if (!Platform.isWindows) return;
    final now = DateTime.now();
    final last = _lastShowAt;
    if (last != null && now.difference(last) < const Duration(milliseconds: 300)) return;
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

  /// 彻底退出：先落盘，再让原生菜单栈解开，最后销毁托盘并 exit。
  Future<void> exitApp() async {
    if (_exiting) return; // 菜单点击会触发两次，只处理第一次
    _exiting = true;
    try {
      final flush = onBeforeExit;
      // 给收尾 2 秒上限：磁盘异常时也必须能退出，不能被落盘卡死。
      if (flush != null) await flush().timeout(const Duration(seconds: 2));
    } catch (_) {}
    // 菜单点击是在原生 `TrackPopupMenu` 的栈里派发的（见类注释第 5 条）：
    // 立刻销毁托盘会把正在执行的菜单对象释放掉。先让出 60ms 等原生栈解开。
    await Future<void>.delayed(const Duration(milliseconds: 60));
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
    // 左键单击：**明确无响应**。
    //
    // 这里必须留空而不是删掉方法：`TrayListener` 的默认实现是空方法，但显式重写
    // 能把「单击不做任何事」钉成契约，避免以后有人又往这里加 show/hide。
    // 双击不靠这个回调的时间差判定（那条路已被移除）——它走底层
    // `TrayIconDoubleClickedEvent`，见 `init()` 里的图标监听。
  }

  @override
  void onTrayIconRightMouseDown() {
    // 原生触发已生效时这里必须什么都不做，否则会弹两次菜单
    // （后一次弹出会把前一次顶掉，表现为「菜单一闪就没了」）。
    if (_menuByNativeTrigger) return;
    // 兜底：老版本 nativeapi 没有 context_menu_trigger，只能自己弹。
    unawaited(() async {
      try {
        await trayManager.popUpContextMenu();
      } catch (e) {
        debugPrint('Nimbo: 手动弹出右键菜单失败：$e');
      }
    }());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    // 这个回调与 MenuItem.onClick 会被同时触发（见类注释第 3 条）。
    // 正常路径已由 onClick 处理，这里保持空实现，避免同一动作跑两遍；
    // 保留重写是为了说明「不是漏了它」，也便于将来插件只派发其一时切换。
  }
}
