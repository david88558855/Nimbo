# 客户端技术栈审查：是否完全使用 Flutter

审查对象：本仓库的**客户端**（`lib/` + `pubspec.yaml` + `.github/workflows/build.yml` + `assets/`）。
审查日期：2026-10-24 · 对应提交 `957958a`

结论先行：**满足「使用 Flutter 开发客户端」的要求。** 客户端代码 100% 是 Dart/Flutter，
仓库内没有 JavaScript / 原生（Kotlin/Java/Swift/C++）源码，也没有 WebView、自定义
MethodChannel、FFI 或外部进程调用。仅有的两个非 Dart 文件是**开发工具**与**设计稿**，
都不进入产物（下表第 6 项）。

---

## 1. 项目结构

| 检查项 | 结果 | 证据 |
|---|---|---|
| 源码是否集中在 `lib/` | ✅ | `lib/` 下 36 个 `.dart`，共 **9124 行**；`test/` 1 个文件 293 行 |
| 目录分层是否典型 Flutter | ✅ | `lib/app`（主题）`lib/core`（模型/存储/限速/解析）`lib/drivers`（协议）`lib/pages`（页面）`lib/state`（状态）`lib/ui`（组件）`lib/platform`（桌面能力）|
| 是否有独立的前端工程（`package.json`、`vite`/`webpack` 配置） | ✅ 无 | 仓库文件类型统计里没有 `.json`/`.js`/`.ts` |
| 是否有原生工程源码入库 | ✅ 无 | 全仓库 `*.kt / *.java / *.swift / *.m / *.cpp / *.c / *.h` 数量为 **0** |
| 是否提交了编译产物/二进制 | ✅ 无 | 全仓库 `*.so / *.dll / *.dylib / *.jar / *.aar / *.exe / *.apk` 数量为 **0** |

`lib/platform/` 名字容易误解：里面是**Dart 文件**，通过插件（`tray_manager`/`window_manager`）
调用系统能力，没有任何原生代码。

## 2. 依赖配置（`pubspec.yaml`）

| 检查项 | 结果 | 说明 |
|---|---|---|
| 是否声明 Flutter SDK 依赖 | ✅ | `dependencies: flutter: {sdk: flutter}` |
| 依赖是否全部来自 pub（Dart/Flutter 生态） | ✅ | 11 个运行时依赖：`dio`、`crypto`、`xml`、`path`、`path_provider`、`flutter_secure_storage`、`dartssh2`、`file_picker`、`desktop_drop`、`tray_manager`、`window_manager` |
| 是否引入 FFI / WebView / JS 桥 | ✅ 无 | 没有 `ffi`、`webview_flutter`、`flutter_js`、`universal_html` 等 |
| 测试依赖 | ✅ | `flutter_test`（SDK）+ `flutter_lints` |
| 资源声明 | ✅ | 仅 `assets/tray.ico`、`assets/tray.png` 两个图片，无 HTML/JS 资源 |
| 是否 `publish_to: 'none'`（应用而非包） | ✅ | 符合客户端形态 |

## 3. 主要源码文件

| 文件 | 职责 | 技术栈 |
|---|---|---|
| `lib/main.dart` | 入口：`WidgetsFlutterBinding` → `AppState.boot()` → `runApp(MaterialApp)` | Flutter |
| `lib/app/theme.dart` | 设计 token + `ThemeData` + 移动端字号换算 | Flutter（`material`） |
| `lib/pages/*.dart`（7 个） | 全部界面：`Scaffold`/`Row`/`Column`/`ListView`/`Dialog`/`SnackBar` 等（统计：Row 72、Container 41、Column 39、SnackBar 29、Dialog 28、StatelessWidget 27、Scaffold 16） | Flutter |
| `lib/state/*.dart` | `ChangeNotifier` + `AnimatedBuilder` | Flutter |
| `lib/drivers/*.dart`（7 个） | FTP/SFTP/S3/WebDAV/本地 五套协议；`dio` + `dart:io` Socket + `dartssh2` | 纯 Dart |
| `lib/core/*.dart`（8 个） | 模型、格式化、凭据存储、限速、上传断点、地址解析 | 纯 Dart |
| `lib/ui/kit.dart` | 自研组件（按钮/徽标/空状态） | Flutter |
| `lib/platform/*.dart` | 托盘/单实例/关窗行为 | Dart + 两个 Flutter 插件 |

**关键判定**：`lib/` 里所有 `import` 只有三类——`dart:*` SDK、`package:flutter/*`、
`package:<纯 Dart 包>`。没有任何一处调用 JS 运行时、原生模块或外部可执行文件
（`Process.run/start` 命中数 0），也没有 `dart:ffi` / `MethodChannel`。

## 4. 构建配置

| 检查项 | 结果 | 证据 |
|---|---|---|
| 构建是否只走 Flutter 工具链 | ✅ | `flutter pub get` / `flutter analyze` / `flutter test` / `flutter build apk --target-platform android-arm64` / `flutter build windows --release` |
| 是否存在自定义 Gradle/CMake/脚本工程 | ✅ 无 | 仓库内无 `android/`、`windows/`；workflow 用 `flutter create --platforms=... --org com.nimbo` 现生成，再用 `sed` 调 `compileSdk`/`minSdk` 与注入 manifest 权限 |
| 是否有自研原生代码参与编译 | ✅ 无 | 同上，平台工程完全由 Flutter 模板生成 |
| 产物形态 | ✅ | Windows 便携 zip（含插件 DLL）、Android arm64 APK，均为 Flutter 标准产物 |

`android/`、`windows/` 等目录被 `.gitignore` 忽略，是**有意的设计**（平台脚手架不漂移），
不是缺失。

## 5. 客户端能力实现方式（是否"纯 Dart"）

| 能力 | 实现 | 判定 |
|---|---|---|
| HTTP / WebDAV | `dio` + 自研 SigV4（S3）、自研 PROPFIND/MOVE 等 | 纯 Dart |
| FTP | 自研协议（`dart:io` Socket） | 纯 Dart |
| SFTP | `dartssh2` + 自研 `SSHSocket` 适配（走代理） | 纯 Dart |
| 代理（HTTP CONNECT / SOCKS5） | 自研（`dart:io` + 手写握手） | 纯 Dart |
| 本地文件 | `dart:io` | 纯 Dart |
| 凭据存储 | `flutter_secure_storage`（系统密钥库）+ 便携混淆文件 | Flutter 插件 |
| 文件选择 / 拖拽 / 托盘 / 窗口 | `file_picker`、`desktop_drop`、`tray_manager`、`window_manager` | Flutter 插件 |
| 本地磁盘剩余容量 | **未实现**（`dart:io` 无 API，需 FFI，按约定不引入） | 能力缺口，非技术栈问题 |

## 6. 非客户端内容（仓库里有、但不参与客户端）

| 内容 | 是什么 | 是否进入客户端产物 |
|---|---|---|
| `tools/push_via_api.py` | 提交代理故障时用 GitHub API 推送的开发脚本 | ❌ 不打包，CI 不执行 |
| `design/index.html` | 设计稿（单文件 HTML，含 1 个 `<script>`） | ❌ `pubspec.yaml` 未声明，不打包 |
| `docs/*.md`、`README.md`、`AGENTS.md` | 交接与决策文档 | ❌ |
| `.github/workflows/` | CI 构建（bash / pwsh 命令） | ❌ 只在构建机执行 |

严格意义上，仓库里存在 Python 与 HTML，「仓库是否零非 Dart 文件」的答案是否定的；
但**客户端代码范围内**（会被编译进应用的）没有任何非 Flutter 内容。

---

## 7. 结论

**当前代码满足「使用 Flutter 开发客户端」的要求：**

- 客户端 **100% Dart/Flutter**：界面全部 Flutter Widget，状态层 `ChangeNotifier`，
  构建仅用 Flutter 工具链，无原生源码、无 JS、无 WebView、无 FFI、无自定义平台通道。
- 不属于「混合技术栈」的判定依据：所有第三方依赖都是 pub 上的 Flutter/Dart 包；
  部分包（`file_picker`/`flutter_secure_storage`/`desktop_drop`/`tray_manager`/`window_manager`）
  内含原生实现——这是 **Flutter 插件生态的标准形态**，不是客户端自带第二套技术栈。

## 8. 潜在风险点（按影响排序）

| # | 风险 | 说明 | 建议 |
|---|---|---|---|
| R1 | **平台目录不入库** | `android/`、`windows/` 每次由 `flutter create` 生成；任何平台侧配置（权限、compileSdk、签名）只能写在 workflow 里，否则下次构建即消失；本地也无法直接 `flutter run` 到这两个工程 | 保持「平台改动一律进 workflow」的约定；接入签名/证书时同步落 workflow |
| R2 | **两个插件依赖 nativeapi/cnativeapi** | `tray_manager ^0.8`、`window_manager ^0.5` 通过 native-assets hook 在**构建期编译 C**：Linux 需 `libgtk-3-dev/libx11-dev/libxi-dev`，Windows 需 MSVC；产物必须整包分发（缺 DLL 会崩） | workflow 已装 GTK 依赖并打整包 zip；新增插件前先确认其构建期依赖 |
| R3 | **插件原生实现带来的平台差异** | 同一功能在 Windows/Android 上的实现不同（托盘、窗口、文件选择），问题只在某一端出现 | 回归清单按平台分组执行（见 `PROJECT-STATUS.md` 第 8 节） |
| R4 | **不支持 Web** | 传输层直接用 `dart:io` Socket + 桌面插件；虽然「纯 Flutter」仍成立，但无法编译到 web | 若未来要 web，需为驱动层抽象出 HTTP-only 实现 |
| R5 | **纯 Dart 约束的代价** | 本地磁盘容量需 FFI（`GetDiskFreeSpaceExW`），按约束未实现；FTPS 需 TLS 升级也尚未做 | 作为已知限制记录在 `PROJECT-STATUS.md` 第 6 节 |
| R6 | **测试覆盖偏窄** | 只有 293 行纯逻辑单测（路径/限速/断点/编码），没有 Widget 测试与协议集成测试 | 若要提高可信度，优先补 S3/WebDAV 的签名与路径单测（已有基础） |
| R7 | **第三方依赖版本互相牵制** | `file_picker 8.x` 与 `desktop_drop` 的 `cross_file` 冲突，升级必须同批处理 | 升级前先看 ADR-12 |
