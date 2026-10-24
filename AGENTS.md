# AGENTS.md

给接手这个仓库的 AI/工程师的最短路径说明。**先读 [`docs/PROJECT-STATUS.md`](docs/PROJECT-STATUS.md)**，
那里有完整现状、关键决策、已知坑与待办；本文只列不可违反的约束和常用命令。

## 三条硬约束

1. **禁止本地编译。** 本机没有 Flutter SDK，也不要安装。所有 `pub get` / `analyze` /
   `build` 只在 GitHub Actions 里发生。提交后用 `gh run view` 看结果。
2. **平台目录不入库。** `android/`、`windows/` 由 CI 用 `flutter create` 现生成；
   任何平台侧改动必须写进 `.github/workflows/build.yml`，否则下次构建前消失。
3. **真相来源是 `lib/` + `pubspec.yaml` + workflow。** 设计稿在 `design/index.html`，
   不要按设计稿反推已实现能力，以实现为准。

## 构建与验证

```bash
# push 到 main 自动构建；也可手动触发
gh workflow run build.yml --ref main
gh run list --limit 3
gh run view <run-id> --json jobs --jq '.jobs[] | "\(.name) => \(.conclusion)"'

# analyze 之后还有一步 flutter test（纯逻辑单测）；它需要先装 gtk3/x11/xi，
# 因为 cnativeapi 的 native assets 会在测试时构建。别删那个步骤。
# 失败只抓失败步骤（CI 日志带 ANSI 色）
JOB=$(gh run view <run-id> --json jobs --jq '.jobs[]|select(.name=="analyze")|.databaseId')
gh run view --job $JOB --log-failed | sed -e 's/\x1b\[[0-9;]*m//g' | grep -E "error •|warning •"
```

`analyze` 约 1.5 分钟，是唯一门禁；`android-arm64` / `windows-x64` 各约 5–6 分钟。
**一次提交只改一类问题**，否则定位成本翻倍。

## 改代码前必须知道的

- `StorageDriver` 的 `downloadTo` / `uploadFile` 签名一变，**五个驱动都要跟着改**；
  新驱动必须在长循环里调用 `onProgress`，否则该协议的暂停/续传失效。
- **新驱动的长循环里还要 `await TransferLimiter.instance.{upload|download}.take(chunk.length)`**，
  否则该协议不受限速影响（限速是全局令牌桶，见 ADR-13）。整条流交给 dio 的场景用
  `throttleStream()` 包一层。
- 续传起点一律"实测"：下载看本地文件长度，上传由驱动实现
  `uploadResumeOffset()`——默认按远端 `sizeOf()` 复核，S3 覆写成按分片状态算。
- S3 分片状态在 `userdata/multipart.json`，续传前**必须**先 `ListParts` 以服务端为准；
  失败不再 Abort（见 ADR-14）。
- WebDAV 上传续传靠 `PUT` + `Content-Range`（partial PUT，非标准）。**写完必须量一次
  总长度**才能判定服务器真的支持，否则会得到一个长度不对却「成功」的文件；
  断点用「大小 + mtime」绑定文件，只记长度会让同名文件拼接出错位内容（见 ADR-17）。
- `file_picker` 锁 8.x、`desktop_drop` 锁 0.8.x，两者互相牵制（`cross_file` 版本冲突），
  升级要同批改。
- 每个传输任务独占一条连接；浏览会话与传输队列是两套连接，别合并。
- **S3 的 Endpoint 可以带子路径**（`https://host/s3`）。前缀必须拼进请求路径与 SigV4 的
  CanonicalRequest，但 `x-amz-copy-source` 只写 `/<bucket>/<key>`。路径拼装只走
  `drivers/s3_path.dart`（有单测），别在驱动里手拼字符串。
- **S3 / WebDAV 的端口属于地址**：表单不给端口框，`mount.port` 存 0，解析一律走
  `core/endpoint.dart` 的 `parseEndpoint()`（驱动与表单共用）。别再给这两个协议加端口输入框，
  也别在驱动里另写 `Uri.parse`。
- **WebDAV 自定义方法必须用 `_dio.request(url, options: Options(method: ...))`**，
  不要用 `_dio.fetch(RequestOptions(...))`——后者不合并 `BaseOptions.headers`，
  `Authorization` 会丢，表现为全站 401。
- **没有「只读挂载」开关了**：`Mount.readOnly` 已删，写操作门禁只看 `activeMount` 是否存在。
  老配置里的 `readOnly` 键会被忽略；不要重新引入这个字段（权限问题应交给服务端 403）。
- **下载目录**：`AppSettings.downloadDir`（空 = 默认）→ `TransferManager.downloadRoot` →
  `downloadDir(root:)`。该函数会建目录 + 写探针，失败静默回落默认目录；
  `localPath` 在入队时算好，改设置只影响新任务。
- 文件页有两种态：`AppState.browseAll`（全部挂载聚合根）与挂载内目录树。
  新增页面级交互时先想清楚在哪个态生效。
- **移动端字号**：Android 上 `MaterialApp.builder` 把文本缩放下限抬到 1.2
  （`kNimboMobileScale`）。因此新增的固定高度/宽度/图标一律用 `uiSize()` 换算，
  写死 `height: 30` 会裁字；含 `uiSize()` 的控件不能加 `const`。
- 传输记录恢复要给**挂载对象**（`restore(saved, mounts)`），不是 id 集合；编辑挂载后
  调 `syncMount()`，否则恢复出来的任务会拿旧地址连。

## 平台相关（Windows）

- `lib/platform/` 下三个能力都只在 Windows 生效，Android 上靠 `Platform.isWindows` 挡掉：
  托盘（`desktop_shell.dart`）、单实例（`single_instance.dart`）、窗口管理。
- 单实例是「端口区间 47913–47922 + 握手」，**不是**固定端口绑不上就退出：
  那样遇到端口被别的程序占用时，双击 exe 会静默无反应。
- **托盘右键菜单必须显式开原生触发器**：`setContextMenuTrigger(ContextMenuTrigger.rightClicked)`
  并读回确认。`tray_manager 0.8` 的 `setContextMenu()` 只挂菜单、不设触发器，而 nativeapi
  的默认值是 `None` —— 结果就是「图标在、右键毫无反应」。`onTrayIconRightMouseDown` 里的
  手动 `popUpContextMenu()` 只在原生触发器没生效时执行，两条路同时开会弹两次。
- **托盘双击**不能只靠兼容层的 `onTrayIconMouseDown` 时间差——`tray_manager 0.8` 的
  legacy 桥接会丢弃 `DoubleClicked`，必须同时监听底层 `TrayIconDoubleClickedEvent`。
  左键单击也会显示窗口，重复调用由 `showWindow()` 的 300ms 去重吞掉。
- 关窗行为由 `setPreventClose(true)` + `WindowListener.onWindowClose` 接管：
  默认收进托盘；托盘没装好（`_trayReady == false`）时必须改为直接退出，否则会变成
  「窗口藏了、托盘也没有」的僵尸进程。
- 托盘菜单的点击会被派发两次（`MenuItem.onClick` + `TrayListener.onTrayMenuItemClick`）：
  动作只写一处且要幂等。`exitApp()` 有 `_exiting` 闸，`showWindow()` 有 200ms 去重。
- `exit(0)` 不走 `dispose()`：所有彻底退出的路径都要先 `onBeforeExit()` 落盘。
- 菜单点击回调跑在原生 `TrackPopupMenu` 栈里，退出前要 `await 60ms` 再
  `trayManager.destroy()`，否则会释放 `Menu::Open()` 正在用的对象。
- **界面字体**：Windows 用内置 Noto Sans SC（`pubspec.yaml` 的 `fonts:` + `assets/fonts/`），
  字族名是 `NotoSansSC`。换字体改 `theme.dart` 的 `kNimboWinFontFamily`，
  且**必须同时改 `appBarTheme.titleTextStyle` 与 `tooltipTheme.textStyle`**（显式样式不继承
  `textTheme`）。别写系统字体名：Windows 没预装思源黑体，会静默回落成雅黑。
- Windows 产物依赖 `cnativeapi.dll` / `window_manager_plugin.dll` 等，**必须整包分发**。
- 便携数据全在 exe 同级 `userdata/`：`prefs.json`、`transfers.json`、`multipart.json`、
  `credentials.dat`。
  `credentials.dat` 是可逆混淆，不要对外描述成"加密"。

## 网络（本沙箱）

`github.com` 需要优选 IP + `mtu 1400` + `http.version=HTTP/1.1` 才能直连；
容器重启会重置 MTU，push 报 `GnuTLS recv error (-110)` 时先重设：
`sudo ip link set eth0 mtu 1400`。仍然失败就用 `tools/push_via_api.py` 走 API 通道。
详见 `docs/PROJECT-STATUS.md` 第 0 节与第 5 节第 16/17 条。

## 取产物

`gh run download` 走 Azure Blob，单连接约 15 KB/s，会卡十几分钟。
正确做法：拿 302 的签名 URL，用 16 路 `curl -r` 分块并发（SAS 10 分钟过期，需现取）。
产物是「zip 套 zip」——外层是 upload-artifact 的打包，内层才是便携目录，分发前拆一层。

## 提交规范

- 中文提交信息，前缀用 `feat(P2):` / `fix(ci):` / `docs:` 这类。
- 改完能力后同步更新 `README.md` 的「当前状态」与 `docs/PROJECT-STATUS.md` 的
  阶段表 / 构建记录 / 待办，让下一个接手的人不用回溯聊天记录。
