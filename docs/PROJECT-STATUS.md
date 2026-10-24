# Nimbo 项目现状与交接说明

> 写给下一位接手的人或 AI。目标：读完这一篇就能继续推进，不必回溯聊天记录。
> 最后更新：2026-10-24 · 已完成 P0–P4 + 一轮全库缺陷审查（结论见 `docs/bug-audit.md`，4 条 P0/P1 待修）

---

## 0. 三分钟上手

| 项 | 内容 |
|---|---|
| 仓库 | `https://github.com/david88558855/Nimbo`（分支 `main`） |
| 产物 | Windows x64 便携 zip + Android arm64 APK |
| **硬约束** | **禁止本地编译**。本机没有 Flutter SDK，所有编译、静态检查、依赖解析只在 GitHub Actions 里发生 |
| **先修什么** | 全库审查出的 16 条缺陷见 [`docs/bug-audit.md`](bug-audit.md)（含批次计划与进度勾选）。**BUG-01/02 会丢配置，先修** |
| 真相来源 | `lib/` + `pubspec.yaml` + `.github/workflows/build.yml`。`android/`、`windows/` **不入库**，每次构建由 CI 现生成 |
| 设计稿 | `design/index.html`（单文件、真实 CSS 渲染、可离线打开，v1.2） |
| 当前版本 | `pubspec.yaml` → `0.4.0+4`；界面上的版本号统一取 `lib/core/version.dart` 的 `kAppVersion` |

**工具链（CI 实测）**：Flutter 3.47.7 stable / Dart 3.13.5 / Java 17（temurin）/
runner `ubuntu-latest` + `windows-latest`。`pubspec.yaml` 的 SDK 约束写的是 `>=3.3.0`，
但代码里只用了保守语法（没有 records 之外的实验特性），升级 Flutter 一般不会炸。

主要依赖：`dio ^5.7`、`dartssh2 ^4.1`、`crypto ^3.0`、`xml ^6.5`、`path_provider ^2.1`、
`flutter_secure_storage ^9.2`、`file_picker ^8.1`（**8.x，API 与 13.x 不同，见第 5 节第 4 条**）、
`desktop_drop ^0.8.4`（**锁 0.8.x，0.9.x 与 file_picker 8 冲突，见 ADR-12**）。

### 常用命令

```bash
# 什么时候会构建：push 到 main / 打 v* tag / PR / 手动触发
gh run list --limit 3                       # 看最近几次
gh run view <run-id> --json jobs \
  --jq '.jobs[] | "\(.name) => \(.conclusion)"'   # 看各 job

# 失败时只抓失败步骤的日志（CI 日志带 ANSI 色，先去掉）
JOB=$(gh run view <run-id> --json jobs --jq '.jobs[]|select(.name=="analyze")|.databaseId')
gh run view --job $JOB --log-failed > ci.log
sed -e 's/\x1b\[[0-9;]*m//g' ci.log | grep -E "error •|warning •"

# 取产物：gh run download 走 Azure Blob 单连接只有 ~15 KB/s，会卡十几分钟
# 实际做法见第 5 节第 17 条：取 302 签名 URL 后用 16 路 curl -r 并发分块

# 推送：优先 git push；若报 CONNECT tunnel failed / HTTP2 framing（本机代理到
# github.com 不通，但 api.github.com 通），改用 API 通道：
python tools/push_via_api.py "提交说明"
```

`tools/push_via_api.py` 用 Git Data API 直接建 blob→tree→commit→ref，
不依赖 git 传输层，因此在代理故障时仍能提交，并会正常触发 Actions。

### 本机通道（重启会丢，接手先确认）

```bash
# 1) 优选 IP：从 https://api.github.com/meta 的 web 段挑能过 TLS 的，
#    实测 20.27.177.113 最快（TLS 0.19 s）
echo "20.27.177.113 github.com" | sudo tee -a /etc/hosts
echo "20.27.177.113 github.com" > ~/.user_hosts

# 2) PMTU 黑洞：不改 MTU 时 git 要 37 s，甚至 90 s 后报 GnuTLS recv error (-110)
sudo ip link set eth0 mtu 1400

# 3) GnuTLS 走 h2 会握手失败，全局锁 HTTP/1.1
git config --global http.version HTTP/1.1

# 4) 认证：设备码流程已完成，token 在 ~/.config/gh/hosts.yml
gh auth status   # 账号 david88558855，scope: repo / workflow / read:org

# 5) 验证
git -c http.version=HTTP/1.1 ls-remote https://github.com/david88558855/Nimbo.git
```

> 当前账号是仓库 owner（admin），可直接 push `main`；`workflow` scope 已具备，
> 改 `.github/workflows/**` 不会被拒。

---

## 1. 当前阶段

| 阶段 | 范围 | 状态 |
|---|---|---|
| **P0 骨架** | 五个驱动能连、能列、能读写；双端外壳；云端构建跑通 | ✅ 完成 |
| **P1 传输闭环** | 上传（file_picker）、传输队列、暂停/继续/取消/重试、速度与剩余时间、SFTP 走代理、S3 分片上传、SFTP 流式 | ✅ 完成（本轮） |
| **P2 体验补齐** | 断点续传、预览、拖拽、多选批量、目录上传下载 | ✅ 完成 |
| **P3 打磨** | 传输记录持久化、S3 目录分页删除、FTP 匿名、返回键逐级+双击退出、移动端长按多选、Windows 托盘/单实例、便携凭据、关闭到托盘 | ✅ 完成 |
| **P4 可靠性** | 限速（上传/下载分开）、SFTP 容量、挂载测试与编辑、WebDAV 临时名 + MOVE、S3 分片续传 + 分片并发、统一错误文案、未知大小不确定进度、纯逻辑单测 | ✅ 完成 |
| **P5 缺陷修复** | 全库审查 16 条（P0×2 / P1×2 / P2×8 / P3×4），批次 A→E 见 `docs/bug-audit.md` | 🟡 待开始（仅审查，未改代码） |

**一句话现状**：五个协议都能真实读写，上传下载都能排队跑，代理对五个协议全部生效；
大文件中断后能接着传（下载全协议；上传 FTP/SFTP/本地按远端大小续传，S3 分片按分片表续传）；
限速、托盘、关闭到托盘、单实例、便携凭据、挂载编辑与单挂载测试连接都已可用；
WebDAV 的上传也能续传（服务器支持 partial PUT 时从临时文件实测长度续写，不支持则自动整份重传）；
剩下的是音视频/PDF 预览、FTPS、本地磁盘容量这几项。

**已知缺陷**：2026-10-24 做过一轮全库审查（`docs/bug-audit.md`）。
功能没有立即不可用的问题，但 **BUG-01（配置并发写）/ BUG-02（挂载解析失败丢配置）**
会在极端情况下让用户「挂载忽然全没了」，建议下一轮优先修这两条。

---

## 2. 已完成工作

### 2.1 设计稿（`design/index.html`）

- 视觉体系取自参考项目 OpenList-Client 的 `lib/core/theme/tokens.dart`：天空青→青绿渐变、
  `#EDF2F8` 画布、20/14/9 圆角体系、桌面 44 / 移动 66 行高
- 章节：概览 → 设计语言 → Windows 四块画板（主窗口/传输中心/挂载管理/连接向导）
  → Android 四屏 → 交互方案 → 协议接入 → 落地映射
- **v1.1 变更**：移除 SMB（改为本地与映射盘），品牌定为 Nimbo
- **v1.2 变更**：单一浅色主题（不提供深色/跟随系统）；代理改为按挂载一对一

### 2.2 工程与构建

- 平台目录不入库，CI 用 `flutter create --platforms=... --org com.nimbo --project-name nimbo` 现生成
- `analyze` 作为前置 job，避免两个平台白等
- Windows 产物打成便携 zip（含 `Nimbo.exe` 与 secure_storage 插件 dll）
- Android 只出 `android-arm64`，`--target-platform android-arm64`

### 2.3 五个存储驱动

| 驱动 | 实现方式 | 列目录 | 上传 | 下载 | 移动 | 容量 |
|---|---|---|---|---|---|---|
| FTP | **自实现协议**（USER/PASS、PASV、MLSD→LIST 回落、RETR/STOR/RNFR/RNTO/MKD/RMD/DELE/SIZE） | ✅ | ✅ | ✅ | ✅ | 不支持 |
| SFTP | `dartssh2`，1 MB 分块流式读写 | ✅ | ✅ 流式 | ✅ 流式 | ✅ | 未实现（恒 null） |
| S3 兼容 | **自实现 SigV4**（不引 SDK），path-style / virtual-hosted 可切 | ✅ ListObjectsV2 | ✅ 含 multipart | ✅ 流式 | ✅ copy+delete | 不支持 |
| WebDAV | `dio` + PROPFIND/MKCOL/MOVE/DELETE/GET/PUT | ✅ Depth:1 | ✅ 流式 | ✅ 流式 | ✅ | 可选（quota） |
| 本地/映射盘 | `dart:io` | ✅ | ✅ | ✅ | ✅ | 恒 null（待接 FFI 或平台查询） |

统一接口见 `lib/drivers/storage_driver.dart`：`connect / close / list / space / readAll /
downloadTo / uploadFile / mkdir / removeEntry / move / probe`，错误统一抛 `DriverException`
（带 `DriverErrorKind`：auth / notFound / permission / network / proxy / unsupported）。

### 2.4 网络与代理层

- `lib/drivers/net.dart`
  - `ProxyTunnel.connect()`：HTTP CONNECT 与 SOCKS5（含用户名密码、域名/IP 两种地址类型），
    握手阶段的字节被剥离后返回 `TunnelSocket`（实现 `Socket`，可继续当普通 socket 用）
  - `buildHttpClient()`：HTTP 代理走 `findProxy`（原生支持 CONNECT），SOCKS5 走 `connectionFactory`
- `lib/drivers/sftp_socket.dart`：`ProxySshSocket implements SSHSocket`，
  把隧道交给 dartssh2 —— 于是 **SFTP 也能走代理**
- FTP：控制连接与数据连接都各自 `ProxyTunnel.connect`
- 代理是**挂载的属性**：随挂载保存/编辑/删除，不读系统代理、不碰系统设置

### 2.5 状态层

| 文件 | 职责 |
|---|---|
| `lib/state/app_state.dart` | 浏览会话：当前挂载、路径、条目、选中项、错误；持有 `TransferManager` |
| `lib/state/transfer_manager.dart` | 传输队列：并发调度、暂停/继续/取消/重试、速度采样、半截文件清理 |
| `lib/core/store.dart` | `Prefs`（prefs.json）+ `SecureStore`（系统凭据库）+ `AppSettings` |

关键行为：

- 队列并发 1–4 可调（设置页），**每个任务新建一条独立连接**，跑完即关
- 进度回调只改字段，UI 由 400 ms 定时器统一 `notifyListeners`（避免每 KB 一次重建）
- 中断实现：`_onProgress` 里检查 `task.abort` 并抛 `TransferAborted`；
  五个驱动的读写循环都会调用 `onProgress`，所以一处生效
- 下载中断会删掉本地半截文件；S3 上传中断会 `AbortMultipartUpload`
- 有任务完成时自动重列当前目录（`AppState._onTransfers` 里比对 done 计数）

### 2.6 UI

- 桌面（≥900 px）：236 px 导航栏（导航 / 挂载列表 / 当前挂载的协议与代理状态）；
  **Windows 不显示顶部的挂载切换器**（见 2.19），宽屏平板仍保留
  + 文件区（面包屑、列表、详情栏）+ 底部传输条
- **文件页根是「全部挂载」聚合视图**：`AppState.browseAll` 为真时渲染挂载卡片网格
  （名称 / 协议 / 地址 / 代理 / 当前标记），点卡片才 `open(mount)` 进目录树；
  面包屑固定为「全部挂载 / 挂载名 / …」，第一段可随时退回。启动与删除挂载后都停在这里。
- 移动：底部四 Tab；文件页头部按钮按宽度收敛（窄屏只留「上传 / 新建」）
- 挂载页：卡片列表、移除确认、代理状态展示
- 添加挂载弹窗：协议选择、动态字段（S3 多出 Bucket/Region/路径风格）、**独立代理区（标注「仅对本挂载生效」）**、连接测试；
  **S3 / WebDAV 不提供独立端口框**，端口写在地址里（见 2.11）
- 传输页：进行中/已结束分组，逐任务暂停/继续/取消，总速度汇总

### 2.7 P2 体验补齐

| 能力 | 实现要点 |
|---|---|
| 断点续传 | `StorageDriver.resume`（None/Download/Upload/Both）+ `sizeOf()`；下载起点以本地文件真实长度为准，上传起点以远端 SIZE 复核；WebDAV/S3 下载用 `Range`，只有 206 才续写，200 自动回退重下 |
| 多选批量 | `AppState` 用 `Set<String>` 按 path 记录选择；批量下载递归展开目录，批量删除串行执行并汇总失败项 |
| 目录传输 | 上传：遍历本地目录 → 保留相对层级入队；下载：广度遍历远端目录 → 本地建同名层级 |
| 拖拽上传 | `desktop_drop ^0.8.4`（0.9.x 与 file_picker 8.x 的 cross_file 冲突） |
| 预览 | 图片 `InteractiveViewer`（≤24 MB）、文本等宽可选中（≤1 MB），超限提示下载 |

**注意**：`file_picker` 锁 8.x 期间不能升 `desktop_drop` 到 0.9.x，否则 pub 求解失败。

### 2.8 P3 打磨（已完成）

| 能力 | 实现要点 |
|---|---|
| FTP 匿名 | `Mount.anonymous` + 表单开关（开启后用户名/密码置灰）；`USER` 之后**按回复码**决定是否补 `PASS`：230 说明直接通过、331 才发密码，匿名默认 `anonymous@` |
| 返回键 | `PopScope`（`canPop` 恒为 false，全部自己处理）：非文件页 → 文件页；多选 → 退出多选；子目录 → 上级；挂载根 → 全部挂载；**到根后第一次只弹提示，2 秒内再按一次才 `SystemNavigator.pop()`** |
| S3 目录删除 | `IsTruncated` + `NextContinuationToken` 循环，不再只删前 1000 个键 |
| 长按多选 | 行内长按进入多选（移动端主入口），单项操作走行尾「更多」菜单 |
| 传输记录持久化 | `core/transfer_store.dart` → `userdata/transfers.json`，保留 60 条；启动恢复为「已暂停」，不自动重跑；状态变化 700 ms 防抖落盘，退出时再落一次 |
| Windows 托盘 | `lib/platform/desktop_shell.dart` + `assets/tray.ico`（脚本生成的 256px 圆角 N）。左键单击无响应、双击与菜单项共用 `showWindow()`、悬停提示 `Nimbo`、右键菜单「显示主窗口 / 退出」（**需显式 `setContextMenuTrigger(rightClicked)`**，见 2.13） |
| 单实例 | `lib/platform/single_instance.dart`：回环 47913 端口，第二个进程写入 `show` 后 `exit(0)`；不用锁文件，进程退出端口自然释放 |
| 便携凭据 | Windows 双写 `userdata/credentials.dat`（固定密钥 XOR + base64），读取优先系统凭据库、失败回落便携文件；删挂载清两边。**这是可逆混淆，不是加密**，只解决「整个目录拷走密码还在」 |
| 关闭到托盘 | `windowManager.setPreventClose(true)` + `WindowListener.onWindowClose`：按设置 `closeToTray` 决定 hide 还是退出（默认收进托盘）。不打开拦截时窗口控件会被销毁，托盘菜单点了也没反应 |

### 2.9 P4 可靠性（本轮）

| 能力 | 实现要点 |
|---|---|
| 限速 | `core/limiter.dart` 的 `TokenBucket`，上传与下载各一个桶，`TransferLimiter.instance` 全局共享；五个驱动的读写循环里 `await bucket.take(chunk.length)`；WebDAV 上传这类「整条 Stream 交给 dio」的场景用 `throttleStream()` 包一层。设置页按 KB/s 配，留空或 0 = 不限 |
| SFTP 容量 | `SftpClient.statvfs('/')`（openssh 扩展）→ `blockSize × totalBlocks / freeBlocks`；服务器不支持扩展时返回 null，界面自动省略「剩余」 |
| 容量展示 | `AppState.space` 在 `open()` 时读一次，文件页标题显示「N 项 · 大小 · 剩余」 |
| 挂载测试连接 | 挂载页逐卡片「测试连接」，凭据取自已保存的安全存储（`testMountWithStoredPassword`），结果就地显示成功条目数或带建议的错误 |
| 挂载编辑 | 复用 `AddMountDialog(existing:)`：字段预填、**密码留空表示不修改**、编辑时不允许换协议（凭据语义不同）；保存后若正在浏览该挂载会立刻重连 |
| WebDAV 原子落盘 | 上传先写 `<name>.nimbo-part`，成功后 `MOVE` 成正式名。正式路径上不会再出现「看起来完整其实缺尾部」的文件 |
| WebDAV 上传续传 | **探测式**：中断后若服务器接受 `PUT` + `Content-Range`（SabreDAV / Apache mod_dav / Nextcloud 等），从临时文件的**实测长度**续写并校验总长度；服务器不支持（400/405/409/415/416/501）或写完长度对不上，就静默降级为整份重传。断点状态存 `userdata/uploads.json`，用「大小 + mtime」把断点绑到具体文件，防止同名同长度的另一个文件拿去拼接 |
| WebDAV 基础路径 | 服务器地址里带路径（`https://host/dav`）不再被丢弃；`sizeOf` 在 HEAD 405/无长度时回落 `PROPFIND Depth:0` |
| S3 分片续传 | `uploadId` + 已完成分片的 ETag 落盘 `userdata/multipart.json`（按 `mountId|key`，校验文件大小与分片大小，7 天过期）；续传前先 `ListParts` 以服务端为准，只补缺失分片；完成后删除状态 |
| S3 分片并发 | 3 路并行 PUT；进度 = 已完成分片字节 + 在传分片已发送字节 |
| S3 Endpoint 子路径 | Endpoint 里的路径前缀（`https://host/s3`）会拼进请求路径与 SigV4 的 CanonicalRequest，`x-amz-copy-source` 仍只写 `/<bucket>/<key>`。路径拼装收敛到 `drivers/s3_path.dart`（纯函数 + 单测）；404 且响应不是 S3 XML 时，错误文案直接提示「可能漏了路径前缀」 |
| 上传续传起点下放 | 新增 `StorageDriver.uploadResumeOffset(localFile, remotePath, hint)`：默认按远端 `sizeOf()` 复核（FTP/SFTP/本地），S3 覆写为看分片状态。队列层不再自己算 |
| 统一错误文案 | `drivers/errors.dart` 的 `describeError()` 按 `DriverErrorKind` 追一句可执行建议（认证/路径/权限/网络/代理/不支持），传输卡片用 `shortError()` 截断 |
| 未知大小进度 | `TransferTask.indicatorValue` 在 `total == 0` 时返回 null → 进度条画不确定态，百分比显示「—」 |
| 恢复任务的挂载登记 | `TransferManager.restore(saved, mounts)` 会把挂载登记进 `_mounts`。**修的是真 bug**：原来只传 id 集合，重启后恢复的任务点「继续」一律报「挂载已不存在」 |
| 纯逻辑单测 | `test/core_logic_test.dart`（路径、令牌桶、分片状态 JSON、错误文案、进度不确定态），CI 在 analyze 后跑 `flutter test` |

### 2.10 移动端字号（本轮）

Android 上整体偏小（设计稿按桌面 1:1 排：正文 10.5–12.5、说明 9–10、按钮 11.5）。
处理方式是**统一乘系数**，而不是逐个改 `fontSize`——后者会把标题/正文/说明的比例拆散。

| 机制 | 位置 | 说明 |
|---|---|---|
| 文本缩放 | `app/theme.dart` 的 `nimboTextScaler()` + `main.dart` 的 `MaterialApp.builder` | Android 上把 `textScaler` 的**下限**抬到 `kNimboMobileScale`（1.2）；系统辅助功能里已经调得更大时原样返回，不叠加（叠加会溢出）。放在 `builder` 里，对话框 / SnackBar / Tooltip 一并生效 |
| 固定尺寸 | `app/theme.dart` 的 `uiSize()` | 控件高度、图标、方形磁贴、列表行高、表格列宽统一按同一系数放大。**只放大文字不放大容器，字会被裁** |
| 布局加固 | `files_page` | 面包屑改成横向可滚动（`reverse: true`，当前目录始终可见）；头部统计文字改 `Flexible` + 省略号；移动端隐藏「修改时间」列，宽度让给文件名；列表行高 `uiSize(56)`；聚合根网格 `mainAxisExtent: uiSize(104)` |
| 头部让位 | `transfers_page` / `mounts_page` | 标题+说明改用 `Expanded`，说明文字可换行，右侧按钮不会被顶出屏幕 |

验收口径：Android 上同屏信息量略降（因为字更大），但不能出现文字被裁、按钮出界、
列表行错位；系统字号调到 1.3 时应用不再叠加放大（沿用系统），调到 0.85 时仍保持 1.2 的下限。

### 2.11 连接配置：端口归入地址（S3 / WebDAV）

S3 与 WebDAV 都跑在 HTTP 上，端口本来就是 URL 的一部分。原来的表单对这两个协议也给了一个
独立的「端口」框，结果会出现两种坏配置：地址里写了 `:8443` 而端口框是 443（谁生效说不清），
或者地址里没写端口、端口只存在 `mount.port` 里（换客户端/换实现就丢）。

**界面变更（`pages/add_mount_page.dart`）**
| 位置 | 变更 |
|---|---|
| 协议切换 | S3 / WebDAV 时**隐藏端口输入框**，并把残留的端口值清空（切回 FTP/SFTP 时重新填默认端口，不会把上一个协议的值带过去） |
| 地址输入框 | 提示改成带端口的示例：S3 `https://s3.example.com:9000`、WebDAV `https://dav.example.com:8443/dav` |
| 解析预览 | 地址下方新增强制实时预览：`将连接 https://dav.example.com:8443 · 基础路径 /dav · 端口 8443（地址中指定）`；地址不合法时直接红字提示原因 |
| 协议说明 | 两个协议的 hint 不再写「· 443」，避免暗示存在端口框 |
| 编辑老配置 | 打开编辑时，若老配置把端口存在 `mount.port` 且地址里没有端口，**自动折进地址**（`https://host:8443/dav`），保存后不丢端口 |
| FTP / SFTP | 端口输入框、默认值与行为**完全不变** |

**解析逻辑变更（`core/endpoint.dart` 新增，两个驱动共用）**
- `parseEndpoint(raw, {defaultScheme: 'https', fallbackPort: 0})` 统一解析「协议 / 主机 / 端口 / 基础路径」：
  没写协议按 `https` 补；端口取地址里的显式端口；地址里没写时用 `fallbackPort`（老配置兜底），再退回协议默认（https 443 / http 80）。
- `S3Driver.connect()`：原来自己 `Uri.parse` 一遍，现在用 `parseEndpoint`（端口只来自地址）。
- `WebDavDriver.connect()`：同样改用 `parseEndpoint`，`_base` 直接取 `endpoint.url`（保留基础路径 + 端口）；
  `mount.port` 只在老配置地址里没写端口时作为兜底。
- 一律只接受 `http://` / `https://`，其它 scheme、空主机、端口越界都会抛 `FormatException`（带可读文案）。

**校验规则变更**
- 新增 `_validationError()`，**「测试连接」与「保存」共用同一套规则**（解决「测试通过、保存报错」的不一致）：
  - S3 / WebDAV：地址必须能被 `parseEndpoint` 解析；不合法时提示「端口请写在地址里，例如 https://dav.example.com:8443」；
  - FTP / SFTP：端口留空 = 用默认端口；填了就必须是 1–65535 的整数，否则直接拦下（原来非法值会被静默换成默认端口，掩盖输入错误）；
  - 本地：仍然只校验目录路径。
- `Mount.port` 对 S3 / WebDAV 固定保存为 0，不再残留历史端口值；`Mount.subtitle` 在 `port == 0` 时只显示主机，
  不再出现 `dav.example.com:0`。

### 2.12 Windows 托盘 / 单实例 / 退出路径（复核 + 加固）

对三条桌面行为做了逐项复核（对照 `tray_manager 0.8` 与 `window_manager 0.5` 的实际源码），
修正了会直接破坏这三条的几处问题。

| 行为 | 结论 | 关键实现 |
|---|---|---|
| 托盘右键菜单含「显示主窗口 / 退出」 | ✅（2.13 修了「右键不弹」） | `setIcon` → `setToolTip` → `setContextMenu(Menu([show, separator, exit]))` → **`setContextMenuTrigger(rightClicked)`**；菜单项走 `MenuItem.onClick`，`onTrayMenuItemClick` 留空（插件会把两者**都**派发，见坑 39） |
| 二次双击 exe 不再启动新实例，而是唤醒已有窗口 | ✅ 加固后 | 端口区间 47913–47922 + 握手（`nimbo:show` → 回 `nimbo`）；只有回包是 Nimbo 才认领，避免「端口被别的程序占用」时误判；判定放在 `WidgetsFlutterBinding` 之前，第二实例连引擎都不启动 |
| 托盘后台运行，仅「退出」能结束进程 | ✅ 加固后 | `setPreventClose(true)` + `onWindowClose` → `hide()`；**托盘未就绪时改为直接退出**（否则窗口藏了、托盘没了，进程变僵尸）；`exitApp()` 幂等 + 退出前落盘 |

本轮修掉的具体缺陷：

1. **单实例端口被占 → 程序打不开**（`platform/single_instance.dart`）：原来固定 47913，
   `bind` 失败就 `return false` → `main` 里 `exit(0)`，用户双击 exe 毫无反应。现在改成
   区间探测 + 握手，端口冲突最多降级为「保护失效」，程序一定能打开。
2. **菜单点击执行两次**（`platform/desktop_shell.dart`）：`tray_manager._onMenuItemClicked`
   先调 `menuItem.onClick`，再遍历 listener 调 `onTrayMenuItemClick`。原来两条路都写了
   动作，「退出」会连跑两遍（销毁托盘 + `exit(0)` + 再销毁）。现在 `onTrayMenuItemClick`
   留空、`exitApp()` 加 `_exiting` 幂等、`showWindow()` 加 200ms 去重。
3. **托盘初始化失败 → 窗口藏起来就再也回不来**：`init()` 里任何一步抛错都会被 `catch`
   吞掉，但 `setPreventClose(true)` 已生效，点 × 仍会 `hide()`。现在只有
   「图标 + 右键菜单都装好」才置 `_trayReady`，否则点 × 直接退出（并 `debugPrint` 原因）。
   另外图标加载失败会退回 `assets/tray.png`（插件是按 `<exe>/data/flutter_assets/...`
   读文件的，便携包必须带 `data/`）。
4. **`exit(0)` 不落盘**：托盘退出走的是 `exit(0)`，不会触发 `dispose()`，最后 700ms 的
   传输进度与最后一次设置会丢。新增 `AppState.flush()`（`Prefs.save` + `TransferStore.save`），
   由 `main` 注入 `DesktopShell.onBeforeExit`，退出前调用（带 2 秒超时，磁盘异常也能退）。
5. **最小窗口尺寸可能超出屏幕**：`940×620` 在高 DPI 小屏上会大于可用区域，窗口顶出屏幕。
   现在按当前视图逻辑尺寸收一次下限（92% / 90%），并只在窗口小于下限时才 resize + center。

### 2.13 托盘右键无菜单（根因：nativeapi 的默认触发器）

现场：托盘图标可见、悬停有提示、左键能唤醒窗口，但**右键完全没有反应**，也没有菜单。

**根因**（对照 `cnativeapi 0.5.2` 的 C++ 实现确认）：

| 层 | 事实 |
|---|---|
| `nativeapi::TrayIcon` | `context_menu_trigger_` 默认初始化为 `ContextMenuTrigger::None`（`tray_icon_windows.cpp` 的 `Impl()` 初始化列表） |
| Windows 消息处理 | `WM_RBUTTONUP` → `Emit<TrayIconRightClickedEvent>()`，**只有** `trigger == RightClicked` 时才追加 `OpenContextMenu()`；`None` 就到此为止 |
| 因此 | 「挂菜单」与「右键弹菜单」是**两件独立的事**：`SetContextMenu()` 只是把菜单存进 `pimpl_->context_menu_`，不会顺带设置触发器 |
| `tray_manager 0.8` 兼容层 | `TrayManager.setContextMenu()` 只调 `_ensureTrayIcon.setContextMenu(...)`，**从不**调 `setContextMenuTrigger()` —— 0.5.x 时代由平台层自动弹，改成 nativeapi 之后这个默认值变了 |

结论：只调 `setContextMenu()` 的 0.8 兼容层用法在 Windows 上等于「菜单挂着但永远不会显示」，
而且没有任何异常或日志，症状就是「右键毫无反应」。

**修复**（`lib/platform/desktop_shell.dart`）：

1. `setContextMenu()` 之后调 `trayIcon.setContextMenuTrigger(ContextMenuTrigger.rightClicked)`，
   并**读回** `getContextMenuTrigger()` 确认生效（老版本 nativeapi 上这个调用会静默无效）。
2. 读回失败时保留兜底路径：`onTrayIconRightMouseDown()` 里手动 `popUpContextMenu()`。
   两条路径互斥（`_menuByNativeTrigger`），否则会弹两次——第二次弹出会把第一次顶掉，
   表现为「菜单一闪就消失」。
3. 左键单击仍保持「空操作」（后按需求明确为无响应）；双击改由底层 DoubleClicked 事件驱动，
   双击会连发两次 down，由 `showWindow()` 的 300ms 去重吞掉（原来用 450ms 时间差
   识别双击的写法一并删掉）。
4. 退出路径加 60ms 让出：菜单点击是在原生 `TrackPopupMenu` 的调用栈里派发的
   （插件用 `TPM_RETURNCMD` 保证点击回调在 `Menu::Open()` 内完成），此时立刻
   `trayManager.destroy()` 会把正在被 `Open()` 使用的菜单对象释放掉（use-after-free）。

`init()` 结束时会打一行日志，便于现场判断走的是哪条路径：
`Nimbo: 托盘就绪（右键菜单触发方式：原生 / 手动兜底）`。

### 2.14 界面收口（移除只读挂载 / 底部凭据提示；下载目录可配；并发默认 3）

| 变更 | 位置 | 说明 |
|---|---|---|
| 移除「只读挂载」 | `core/models.dart`、`pages/add_mount_page.dart`、`pages/files_page.dart`、`pages/mounts_page.dart`、`pages/shell.dart`、`state/app_state.dart` | 模型字段、表单开关、文件页 9 处写操作门禁、挂载页「只读」徽标、侧栏「只读/可读写」、`AppState.readOnly` 全部删掉。**老配置里的 `readOnly` 键读的时候直接忽略、保存时不再写回**（`Mount.fromJson` 不认未知键），不会因为旧配置文件报错 |
| 移除弹窗底部提示 | `pages/add_mount_page.dart` | 「凭据只写入系统安全存储，不落配置文件」那段文字连同盾牌图标一起删掉，底部只剩「测试连接 / 保存」按钮（用 `Spacer` 右对齐） |
| 下载目录可配 | `core/store.dart`、`state/transfer_manager.dart`、`pages/settings_page.dart` | `AppSettings.downloadDir`（空 = 默认）+ 设置页「选择目录…/恢复默认」。`downloadDir(root:)` 用**写探针**验证目录可写，失败静默回落默认目录（Windows `下载/Nimbo`，其它 `文档/Nimbo`） |
| 并发默认 3 | `core/store.dart`、`state/transfer_manager.dart`、`pages/settings_page.dart` | 默认值 2 → 3。老 `prefs.json` 里的 2 是**旧默认值写进去的**，靠新增的 `maxConcurrentPinned` 区分「用户选过」与「默认写入」，没选过的一律升到 3 |

下载目录的两个细节：

- 只影响**新入队**的任务。已经在队列里的任务保留入队时算好的 `localPath`，
  否则改设置会让跑了一半的任务写到另一个文件。
- 目录被删 / 没权限 / 路径变成文件时不再报错，而是回落默认目录并照常下载
  （写探针失败即判定不可用）。

### 2.15 Windows 界面字体：Arial（系统字体，不打包）

**为什么换成 Arial**：上一版内置的思源黑体只带了 400/500/700 三个字重，界面里大量
`w600 / w700 / w800` 全被匹配到 500 或 700，加上思源黑体本身笔画偏厚，整体观感「发粗」。
Arial 的拉丁字形笔画细而均匀，且是 Windows 各版本（Win7 起）都随系统安装的核心字体，
**不需要打包**——顺带把上一版内置的 24 MB 字体文件全部删掉了。

| 项 | 取值 |
|---|---|
| 字族名 | `Arial`（系统字体名，非 family 别名） |
| 可用性 | Windows 7/8/10/11 全部自带（`C://Windows//Fonts//arial.ttf`），无需内置 |
| 中文 | **Arial 不含 CJK 字形**，中文由回落链 `Microsoft YaHei UI` → `Microsoft YaHei` 提供 |
| 符号兜底 | 链尾 `Segoe UI`（雅黑也不覆盖的符号 / emoji 走系统字体链接） |
| 生效范围 | 仅 Windows（`defaultTargetPlatform == windows`）；Android/macOS 保持 Flutter 默认字体 |
| 包体 | **0 增加**（`assets/fonts` 与 `pubspec` 的 `fonts:` 段已删除） |

**改动位置**

| 位置 | 改了什么 |
|---|---|
| `lib/app/theme.dart` | `kNimboWinFontFamily = 'Arial'`；`kNimboWinFontFallback = [雅黑 UI, 雅黑, Segoe UI]`；`buildNimboTheme()` 把它传给 `ThemeData.fontFamily / fontFamilyFallback` |
| `lib/app/theme.dart` 组件主题 | `appBarTheme.titleTextStyle` 与 `tooltipTheme.textStyle` 是**显式**样式、不继承 `textTheme`，由 `withFont()` 补字族 |
| `pubspec.yaml` | 删除 `flutter.fonts`（`NotoSansSC` 三个字重）——改用系统字体后没有本地字体需要声明 |
| `assets/fonts/` | 整个目录删除（3 个 OTF + OFL.txt，约 24 MB） |
| 各页面的 `TextStyle(fontSize: …)` | **不用改**：`inherit` 默认 true，会合并到主题给出的 `DefaultTextStyle` |

**注意中英混排**：一段文字里英文/数字用 Arial、中文用雅黑，是 Windows 原生应用的常见组合
（雅黑自带拉丁字形，会有个别字符落到雅黑）。这是「用 Arial」的固有结果，不是 bug。

**验证方式**
1. Windows 启动后看「Nimbo」「FTP」「S3」等拉丁文字——应为 Arial 的细笔画（`i`、`l` 竖线等宽，
   `a` 双层结构）；对照改前截图，整体明显变细；
2. 中文（「独立代理」「添加挂载」）应仍是雅黑，且**不能出现豆腐块**；
3. 文件名 `𠮷🙂测试.txt` 能正常显示（回落链生效）；
4. 布局：行高/换行与改前一致，表格列宽不被撑开。

### 2.16 设置页收口 + 点文件默认隐藏

| 变更 | 位置 | 说明 |
|---|---|---|
| 删除并发任务右侧说明 | `pages/settings_page.dart` | 去掉「每个任务独占一条连接；FTP 建议 1–2」，只留「并发任务」标签与 1–4 芯片 |
| 删除「单实例 / 托盘」两行 | 同上（桌面卡片） | 卡片里只保留「关闭窗口时收进托盘」开关与其行内说明；分隔线一并删除 |
| 删除「安全」卡片 | 同上 | 4 行静态说明（凭据存储 / 便携备份 / 代理 / 明文 FTP）整体移除 |
| 删除「关于」卡片 | 同上 | 版本 / 协议 / 代理 / 构建 4 行整体移除；`kAppVersionLabel` 不再使用，`core/version.dart` 的 import 一起删掉。版本号仍在左侧导航栏显示 |
| 点文件默认隐藏 | `core/store.dart` | `AppSettings.hideHiddenFiles` 默认 `true`；`load()` 改为 `!= false`——老配置没有这个键时按「隐藏」处理，用户显式关掉才展开。设置页「隐藏以「.」开头的文件」开关保留，可随时关 |

行为影响：升级后首次进入目录，`.` 开头的文件/目录（`.git`、`.DS_Store`、`.thumbnails` 等）默认不显示；
关掉开关后立刻按新规则重筛当前列表（`AppState.updateSettings` 里已有这条重列逻辑）。
注意这只是**显示过滤**，不影响列举本身、也不影响传输：已入队/已完成的任务记录不受影响。

### 2.17 删除「数据」卡片 + 下载目录默认值按平台

| 变更 | 位置 | 说明 |
|---|---|---|
| 删除「数据」卡片 | `pages/settings_page.dart` | 去掉「数据目录 / 存储方式 / 配置文件」三行只读信息，设置页只剩主题、传输、桌面（Windows）三块可交互内容 |
| Android 默认下载目录 | `state/transfer_manager.dart` | 由「应用文档目录/Nimbo」改为公共下载目录 `/storage/emulated/0/Download/Nimbo`（文件管理器、微信、QQ 都能直接看到） |
| Windows 默认下载目录 | 同上 | 保持系统下载目录 `%USERPROFILE%\Downloads\Nimbo`（即资源管理器里的「下载」） |
| 回落链 | 同上 | 用户指定目录 → 平台默认目录 → 应用文档目录，每级都用**写探针**验证；任一级不可写就自动降级，下载不会失败 |
| Android 权限 | `.github/workflows/build.yml` | 注入 `WRITE/READ_EXTERNAL_STORAGE`（`maxSdkVersion=29`）——Android ≤10 直接写公共目录需要它；11+ 不声明（分区存储下该权限无效） |

**Android 11+ 的现实约束**：分区存储下即使声明权限也写不了 `/storage/emulated/0/Download`，
除非用户手动授予「所有文件访问」（`MANAGE_EXTERNAL_STORAGE`，Play 商店对该权限有限制）。
本项目没有引入这个高权限，因此 11+ 设备上写探针会失败、**自动回落到应用私有目录**
（`/storage/emulated/0/Android/data/<包名>/files/Nimbo` 一带），下载照样能完成。
如果你的目标机型是 Android 11+ 且必须落在公共 Download，需要单独决定是否申请该权限
（属产品/合规决策，不是代码补一行就能解决）。

**验证方式**
1. Windows：下载任意文件 → 落在「下载\Nimbo」；设置里改目录后新任务落到新目录；
2. Android ≤10：下载 → 落在 `内部存储/Download/Nimbo`；
3. Android 11+：下载 → 若未授予「所有文件访问」，落在应用私有目录且**不报错**；
   授予后再下载即落到公共目录；
4. 设置页「下载目录」显示「默认：下载/Nimbo」或「默认：内部存储/Download/Nimbo」。

### 2.18 添加挂载弹窗：安卓端两处布局修正

| 问题 | 根因 | 修法 |
|---|---|---|
| 「独立代理」行文字顶出容器 | `Row([Switch, 「独立代理」, 「仅对本挂载生效，不影响其他挂载」])` 里那段说明没有可收缩包裹，Android 放大 1.2 倍字号后总宽超过弹窗宽度 | 删掉右侧说明文字，只留 `Switch + 「独立代理」`（说明本身就是补充信息，标题已足够） |
| 底部两个按钮向右偏 | 上一轮把底部改成 `Row` 开头 `Spacer()` 靠右，配 `fromLTRB(20, 10, 16, 12)` 的非对称内边距，窄屏上看起来像错位 | 去掉 `Spacer`，改 `mainAxisAlignment: center`，内边距对称为 `fromLTRB(16, 10, 16, 12)` |

两处都只动布局：按钮尺寸、间距（8 px）、颜色、圆角与弹窗其余部分不变。

### 2.19 侧栏「挂载切换器」在 Windows 隐藏

截图里那块「未选择挂载 / 点击选择」是侧栏顶部的 `_MountSwitcher`（下拉切换挂载 + 「添加挂载」）。
在 Windows 上它是**重复入口**：侧栏下方已经有完整挂载列表（点一下就切），「挂载管理」页也能
添加/编辑/删除挂载。所以按平台收口：

| 平台 | 行为 |
|---|---|
| Windows | 不渲染 `_MountSwitcher`，侧栏顺序变成「品牌栏 → 导航 → 挂载列表 → 代理状态」 |
| Android 平板（宽屏） | 保持原样，仍显示切换器 |
| 手机（< 900 px） | 本来就不用侧栏（底部 Tab），无影响 |

实现：`pages/shell.dart` 的 `_Rail` 里用
`if (defaultTargetPlatform != TargetPlatform.windows) ...[切换器 + 间距]` 包住，
组件本身与 `onAddMount` 回调都保留（平板还在用），不做删除。
其余逻辑（挂载列表选中态、`AppState.open()`、添加挂载弹窗）完全没动。

### 2.20 Windows 下载目录跟随系统「下载」

原来写死 `%USERPROFILE%\Downloads\Nimbo`：用户把「下载」改到 D 盘、或被 OneDrive 接管后，
文件会落到用户根本找不到的旧路径。现在按系统真值取：

1. 读注册表 `HKCU\...\Explorer\User Shell Folders` 的
   `{374DE290-123F-4565-9164-39C4925E467B}`（下载已知文件夹，`REG_EXPAND_SZ`）；
2. 值里可能是 `%USERPROFILE%\Downloads`，用环境变量展开；
3. 展开失败 / 键不存在才退回 `%USERPROFILE%\Downloads`；
4. 最后拼 `\Nimbo` 作为应用子目录。

实现：`state/transfer_manager.dart` 的 `_windowsDownloadsDir()` / `_queryShellDownloads()` /
`_expandWindowsEnv()`；`_platformDownloadPath()` 因此变成 async。设置页指定的目录优先级更高。

### 2.21 多挂载常驻连接（不再「切换即断开」）

原来只有一个 `StorageDriver`：点另一个挂载会 `close()` 掉前一个，来回切换要反复握手，
正在跑的浏览也会被打断。现在改成**每挂载一个常驻会话**（OpenList 的「多个存储同时在线」）：

| 位置 | 改动 |
|---|---|
| `AppState` | `Map<String, StorageDriver> _sessions` 取代单字段 `_driver`，`_driver` 变成按当前挂载查表 |
| `AppState.sessionFor(mount)` | 取或建会话（同一挂载只留一份）；`reconnect: true` 时先关旧会话 |
| `AppState.warmUp()` | 启动后**后台**并行连接所有挂载，失败只写 `_sessionErrors`，不抛、不影响其它挂载 |
| `AppState.open(mount)` | 复用已存在的会话（切回来是瞬时的），不再关别的挂载；连接失败才 `dropSession` |
| `updateMount` / `removeMount` | 先 `dropSession` 再按需重连：改配置后旧会话必须作废，删挂载要释放连接 |
| `isConnected(id)` / `mountError(id)` | 供 UI 显示状态 |
| `pages/files_page.dart` | 挂载卡片的状态点改为真实连接状态，文案「当前浏览」/「协议 · 已连接 / 未连接」 |
| `pages/pick_destination.dart` | 选目标目录时也用 `sessionFor`，可跨挂载，目标挂载按需连接且用完不销毁 |

**预期行为**：启动后各挂载在后台陆续连上；在一个挂载里复制到另一个挂载时两边会话同时存在；
切换挂载不再有握手等待；某个挂载密码错误只让它自己显示「未连接」。

### 2.22 复制 / 移动

**驱动层**（`drivers/storage_driver.dart`）：新增 `copyEntry(RemoteEntry from, String to)`。
默认实现是「下载到系统临时文件 → 再上传」，五个协议都能跑，但大文件慢。按协议覆写：

| 驱动 | 实现 |
|---|---|
| 本地 | `File.copy`（+ 补建父目录） |
| WebDAV | 服务端 `COPY`（`Destination` + `Overwrite: T`） |
| S3 / SFTP / FTP | 默认的临时文件中转（`CopyObject` / `copy-data` 扩展留给后续） |

**编排层**（`AppState.copyOrMoveEntries`）：三条路径按代价选最优
- 同挂载 + 移动 → `move()`（rename，目录整棵 rename，一次系统调用）
- 同挂载 + 复制 → `copyEntry`（目录递归：先 `mkdir` 再逐个文件）
- 跨挂载 → 逐文件「下载到临时文件 → 上传」，移动成功后再删源
- 目录不能复制/移动进自己或自己的子目录（会无限递归），提前拦截并给可读提示
- 单项失败不中断整批，最后汇总抛 `DriverException`

**界面**（`pages/files_page.dart`）
- 行内「更多」菜单：新增「复制到…」「移动到…」
- 移动端长按菜单：同样两项
- 多选条：新增「更多操作」溢出菜单（复制到… / 移动到…）——不放按钮是为了窄屏不挤压文字
- 目标选择器（`pages/pick_destination.dart`）：先选挂载，再逐级进目录，「上一级」可退回挂载列表；
  底部实时显示「目标：挂载名/路径」

**预期行为**：复制/移动后刷新当前目录并提示「已复制/移动 N 个文件到 挂载名/路径」；
移动是剪切语义（源消失）；跨挂载复制走本地中转，速度受两端带宽限制。

### 2.23 桌面端「返回上层」按钮

文件页标题行右侧按钮组新增一个 `返回上层`，排在「上传」左边：

```
[返回上层] [上传] [新建文件夹] [选择] [挂载管理]
```

| 项 | 取值 |
|---|---|
| 组件 | `NimboButton('返回上层', icon: Icons.arrow_upward_rounded)`（默认 secondary：白底 + 0.5px 边框 + 圆角 8） |
| 尺寸 | 默认高 30（与「上传」完全同高），宽由文字撑开 |
| 显示条件 | `compact == false`，即**仅桌面宽屏（≥900px）**；移动端不加（系统返回键/侧滑返回已覆盖，标题行宽度也放不下） |
| 可用条件 | `state.browseAll == false`（已在某个挂载内）可点 → `state.up()`：子目录回上级、挂载根回「全部挂载」；停在聚合根时 `onPressed: null` 置灰 |
| 与面包屑/返回键的关系 | 三者都走 `AppState.up()`，行为必然一致 |

为什么不做主色填充：工具栏里「上传」是主操作，返回上层是导航动作，同色会抢焦点。

### 2.24 挂载卡片重排（操作区右对齐、按钮统一 28）

原来的卡片是「标题行 + 地址行 + 状态行」，删除图标塞在标题行 `Spacer` 之后、测试/编辑/打开
塞在状态行末尾，且按钮高 26 与卡片高度不匹配，看起来一个高一个矮、删除还浮在中间。

现在：`LayoutBuilder` 判断宽度，宽屏 `Row[Expanded(信息), 操作组]`、窄屏（< 560）操作组换行右对齐。

| 位置 | 说明 |
|---|---|
| `pages/mounts_page.dart` `_MountCardState._info()` | 三行信息：协议徽标 + 名称（13/w800）/ 地址（mono 10）/ 连接方式（10.5 + 图标） |
| 同上 `_actions()` | `测试连接（ghost）→ 编辑（secondary）→ 打开（primary）│ 删除（danger）`，全部 `height: 28`，间距 7，删除前 3+1+3 的竖分隔线 |
| `ui/kit.dart` | `NimboButtonKind.danger` 改为**常态浅红底** `#FCEBEB` + `dangerInk` 文字，去掉描边（悬停由 InkWell 覆盖色提亮） |

`onTest / onEdit / onOpen / onDelete` 四个回调签名与调用时机完全没动。

### 2.25 显示名称：不预设默认值，必填校验（空值 / 纯空格都拦）

字段原来写死 `新挂载`（切协议时还会变成「本地目录 / 对象存储」），用户清空后保存会**静默**取
协议名，既没提示也不符合「必填」的预期。现在改为**默认空 + 强制手填**：

| 项 | 行为 |
|---|---|
| 默认值 | 无。`TextEditingController()` 空启动，新建弹窗里「显示名称」就是空的 |
| 输入提示 | `必填，例如「家里的 NAS」` |
| 空值 | 「测试连接」与「保存」都被拦下，提示 `显示名称不能为空，请填写一个便于识别的名字（如「家里的 NAS」）` |
| 纯空格 | 同样被拦，但提示区分开：`显示名称不能只填空格，请填写有效字符` |
| 校验时机 | `_validationError()` 在 `_save` / `_test` 的最前面执行（两者共用同一套规则），提交前一定先过这一关 |
| 保存兜底 | **已移除**。`_buildMount()` 直接用 `_name.text.trim()`，不再回退成协议名——否则「看着空、存下去变成 WebDAV」这种不一致又会回来 |
| 编辑模式 | 带出已保存的名称；把它清空后保存一样会被拦 |

上一版那套「按地址推导 + 自动跟随」的实现已整体删除（`_suggestedName` /
`_applySuggestedName` / `_nameTouched` / `_syncingName` / `_ensureName` 全部移除），
避免两套命名策略并存。

---

## 3. 文件地图

```
lib/
  main.dart                    入口：单实例 → boot() → NimboApp；Windows 首帧后初始化托盘
  app/theme.dart               设计 token（颜色/字号/圆角）+ ThemeData（单一浅色）
  core/
    models.dart                Mount / ProxyConfig / RemoteEntry / TransferTask（含 toJson/fromJson）/ 枚举与扩展
    format.dart                路径拼接与规范化、字节/速度/时间格式化、文件类型→图标与配色
    store.dart                 AppPaths（便携 userdata）、Prefs、SecureStore（系统凭据 + Windows 便携双写）；
                               含 AppSettings（并发默认 3、下载目录、限速、关闭到托盘）
    transfer_store.dart        传输记录持久化（userdata/transfers.json，保留 60 条）
    endpoint.dart              S3 / WebDAV 地址解析（协议 / 主机 / 端口 / 基础路径），表单与驱动共用
    multipart_store.dart       S3 分片上传状态（userdata/multipart.json，含 uploadId 与分片 ETag）
    upload_checkpoint.dart     WebDAV 上传断点（userdata/uploads.json，大小 + mtime + offset）
    json_store.dart            小 JSON 状态文件的串行化读-改-写 + 原子落盘（上面两个共用）
    limiter.dart               令牌桶限速（上传/下载各一个桶 + throttleStream）
    version.dart               版本号单一来源（kAppVersion / kAppVersionLabel）
  platform/                    ← 仅 Windows 生效，Android 上全部被 Platform.isWindows 挡掉
    desktop_shell.dart         托盘图标/右键菜单/窗口显隐；单击与双击都显示，右键靠原生
                               setContextMenuTrigger(rightClicked) + 手动兜底
    single_instance.dart       回环端口 47913 的单实例保护
  drivers/
    storage_driver.dart        统一接口 + DriverException + Capability + uploadResumeOffset
    errors.dart                describeError / shortError（按 DriverErrorKind 给可执行建议）
    net.dart                   ProxyTunnel（CONNECT/SOCKS5）+ TunnelSocket + buildHttpClient
    factory.dart               createDriver / testMount（凭据从安全存储取）
    ftp_driver.dart            自实现 FTP（含 _FtpSession 行协议解析）
    sftp_driver.dart           dartssh2 + 流式读写
    sftp_socket.dart           ProxySshSocket（SSHSocket 适配）
    s3_driver.dart             自实现 SigV4 + multipart
    webdav_driver.dart         dio + WebDAV 方法
    local_driver.dart          dart:io
  state/
    app_state.dart             浏览会话
    transfer_manager.dart      传输队列
  pages/
    shell.dart                 自适应外壳（桌面 Rail / 移动 NavigationBar）
    files_page.dart            文件列表、详情栏、上传入口、多选条、拖拽接收、底部传输条
    pick_destination.dart      复制/移动的目标目录选择器（先选挂载再进目录，可跨挂载）
    preview_page.dart          图片/文本预览对话框（canPreviewEntry + showPreview）
    transfers_page.dart        传输任务列表
    mounts_page.dart           挂载管理
    add_mount_page.dart        添加挂载弹窗（含代理与连接测试）
    settings_page.dart         数据/传输/安全/关于
  ui/kit.dart                  按钮、协议徽标、状态点、空状态、输入框装饰
test/core_logic_test.dart    纯逻辑单测（路径 / 令牌桶 / 分片状态 / 错误文案 / 进度）
assets/
  tray.ico / tray.png          Windows 托盘图标（256px 圆角 N，脚本生成，无需设计源文件）
design/index.html              设计稿
docs/s3-addressing-analysis.md S3 寻址模式与第三方兼容性分析（含 Endpoint 子路径）
docs/tech-stack-audit.md      客户端技术栈审查（是否完全使用 Flutter + 风险点）
docs/bug-audit.md             全库缺陷清单（16 条，含批次计划 / 验收标准 / 进度勾选）
docs/PROJECT-STATUS.md         本文档
tools/push_via_api.py          git 通道不通时的 API 推送脚本
```

---

## 4. 关键决策（为什么这么做）

**ADR-01 去掉 SMB，改为「本地与映射盘」**
Dart 生态没有成熟 SMB2/3 实现，自研或 FFI 绑 libsmb2 都会破坏「纯 Dart」约束且风险最高。
NAS 场景的三条替代路径：Windows 映射网络驱动器 → 当本地盘；NAS 开 WebDAV；NAS 开 SSH 走 SFTP。
代价：应用内不能浏览未映射的共享。

**ADR-02 不引各家 SDK，S3 与 FTP 自己实现**
约束是「网络与存储能力全部用 Dart 库实现」。S3 只用到 SigV4 + ListObjectsV2 + PutObject +
Multipart + Copy + Delete，自实现比引 SDK 更可控，也避免 SDK 与代理层打架。
FTP 自实现的原因更硬：需要控制连接与数据连接**都**能走自定义隧道，第三方包的 socket 不可注入。

**ADR-03 代理一对一绑定挂载，没有全局开关**
「有些存储只在特定网络可达」是真实场景。做成挂载属性后，A 直连 + B 走代理可以同时存在，
改 B 不影响 A。实现上五个驱动共用 `ProxyTunnel`，代理只在连接层写一次。

**ADR-04 每个传输任务一条独立连接**
FTP 的控制连接一次只能跑一个传输，共用会话会让「同时上传+下载」互相阻塞；
独立连接还让暂停/取消一个任务不会惊动其他任务。代价是并发 2 时最多 3 条连接（含浏览会话）。

**ADR-05 中断统一用「进度回调抛异常」**
五个驱动的循环里都有 `onProgress` 调用点，在这里抛 `TransferAborted` 是最小改动、
且对全部协议一致的中断方式。**新增驱动时必须调用 `onProgress`，否则该协议的暂停会失效。**

**ADR-06 S3 签名用真实 payload sha256**
早期用 `UNSIGNED-PAYLOAD`，但明文 HTTP 下 AWS 不接受该值（只有 HTTPS 允许）。
改为对 body 求 sha256：分片 8 MB、单文件上限 8 MB 时开销可忽略，且对 MinIO 等自建实现兼容性更好。

**ADR-07 S3 上传切分片，失败即 Abort**
> 8 MB 自动 multipart，分片数控制在 900 以内（协议上限 10000，留余量）。
任一片失败或用户暂停都会 `DELETE ?uploadId`，避免留下永远不发 Complete 的碎片。

**ADR-08 单一浅色主题**
一套 token → 对比度校验、截图回归、图标插画资源都只维护一份。设置页没有「外观」分区。

**ADR-09 平台目录不入库**
仓库里只有 `lib/` 是权威，平台脚手架永远不会与 Flutter 版本漂移。
代价：**任何平台侧改动都必须写进 workflow 的 scaffold 步骤**，直接改 `android/` 会在下次构建前消失。

**ADR-10 compileSdk 抬到 36（CI 里的 sed）**
`file_picker 8.x` 仍写死 `compileSdk 34`，而传递依赖 `flutter_plugin_android_lifecycle`
要求 36，AAR metadata 检查直接失败。CI 在 scaffold 后统一把 app 与 pub-cache 里写死的
compileSdk 抬到 36（只动 compileSdk，不碰 targetSdk/minSdk）。**这个步骤不要删。**

**ADR-11 续传起点一律「实测」，不信任内存计数**
内存里的 `task.transferred` 只是「已经交给 socket」的字节，不等于对端落盘量。
所以下载续传起点取**本地文件真实长度**，上传续传起点取**远端 `SIZE`/`stat` 的返回值**；
两者与记录不一致时以实测为准，宁可重传也不拼出一个错位文件。
HTTP 类只接受 `206 Partial Content`：服务器返回 200 说明忽略了 Range，必须从头覆盖。

**ADR-12 desktop_drop 锁 0.8.4**
`desktop_drop >= 0.9.0` 依赖 `cross_file ^0.4.0`，`file_picker 8.x` 依赖 `^0.3.3+7`，
两者无法共存（pub 直接求解失败）。0.9 的新 API（`onDrop`/`DropFileItem`）暂时用不了，
只能用 0.8.4 的 `onDragDone`/`DropDoneDetails.files`。
**升级 `file_picker` 到 12.x 时，可以顺手把 desktop_drop 升到 0.9.x，但两者必须同批改。**

**ADR-13 限速用全局令牌桶，在驱动循环里取令牌**
dio 的 `onSendProgress` 是同步回调，没法在里面 `await`；而各驱动的读写循环本来就是
async 的。所以把桶放在 `TransferLimiter.instance`，驱动在自己循环里
`await bucket.take(chunk.length)`——一处生效、五个协议一致，也不用改 `ProgressFn` 签名。
代价：驱动层依赖了一个全局单例（可接受，它只影响速率，不影响正确性）。
**新增驱动必须在长循环里取令牌**，否则该协议既不限速、暂停也会在该循环里失效。

**ADR-14 S3 分片失败不再 Abort，改为保留断点**
v1 的约定是「任何失败都 AbortMultipartUpload，避免垃圾分片」。加了续传之后这条不再成立：
用户暂停一次就把已传完的几 GB 分片全丢掉，代价远大于清理成本。现在改为把状态落盘、
失败只保留，交给 S3 的 lifecycle 规则回收（未完成分片本来就该由服务端兜底）。
真正的取消（用户点 ×）目前与「暂停」在驱动层无法区分，因此也留着状态，最多多占一点存储。

**ADR-15 WebDAV 上传写临时名再 MOVE**
WebDAV 没有标准追加写，也不能保证中断回滚。直接 PUT 正式名会留下「看起来完整其实缺尾部」
的文件——比失败更糟，因为用户不会重传。改为 `<name>.nimbo-part` + `MOVE`：
正式路径要么是旧文件要么是新文件。代价是同目录会短暂出现临时文件，异常退出可能残留。

**ADR-16 上传续传起点下放到驱动**
原来队列层统一用「远端 sizeOf 复核」，但 S3 分片上传远端根本没有对象（只有 uploadId），
`sizeOf` 恒为 -1，等于永远不续传。改成 `StorageDriver.uploadResumeOffset()`：
默认实现保留原语义，S3 覆写成「查分片表算已完成字节」。这样 S3 才能真正续传，
队列层也不再需要知道协议差异。

**ADR-17 WebDAV 上传续传做成「探测 + 自校验 + 降级」**
标准 WebDAV 没有追加写。`PUT` + `Content-Range` 属于 RFC 7231 的 partial PUT，
实现程度因服务端而异（SabreDAV / Apache mod_dav / Nextcloud 支持，很多轻量实现直接
400 或把半段当成整份写进去）。所以不能声明「支持上传续传」，而是三步：
① 从远端临时文件的实测长度取起点；② 写完**量一次总长度**，不匹配即判定不支持；
③ 不支持就整份重传（临时文件被覆盖写，不会拼出错位内容）。
断点用「大小 + mtime」绑定到具体文件：只有 `length` 是不够的——同名同长度的另一个文件
会拿别人的前缀拼出一个长度正确、内容错位的文件。代价：文件被 touch 过就失去续传资格，
这是安全的失败方向。

**ADR-18 移动端字号用「全局缩放系数 + 尺寸换算」，不逐处改 fontSize**
字号散落在 30 多个文件、上百处 `TextStyle(fontSize: ...)`，逐个改既容易漏，也会破坏
「标题 26 / 正文 12.5 / 说明 9」这套比例。改成两件事：
① `MaterialApp.builder` 里把 Android 的 `textScaler` 下限抬到 1.2（字号全部等比放大，
层级关系不变，且尊重系统的辅助功能设置）；② 用 `uiSize()` 把固定高度/宽度/图标同步放大。
代价：所有新增的固定尺寸都必须走 `uiSize()`，写死的 `height: 30` 会在移动端裁字。

**ADR-19 S3 / WebDAV 的端口归入地址，不再单列**
这两个协议都基于 HTTP，端口属于 URL。单列端口会制造两个真相来源（地址里的端口 vs 端口框），
并且让 `mount.port` 变成一半协议用、一半协议不用的模糊字段。所以：
表单不再给端口框、`mount.port` 存 0、解析统一走 `parseEndpoint()`，驱动与表单共用同一套规则。
老配置的兼容只在「编辑」时做一次折算（把 `mount.port` 折进地址），运行期不改用户数据——
WebDAV 驱动仍把 `mount.port` 当作「地址里没写端口」时的兜底。

**ADR-20 S3 的 Endpoint 路径前缀必须参与请求路径与签名**
`https://demo.foxel.cc/s3` 这类网关型部署，前缀不是装饰而是路由：丢了它请求会落到站点根，
拿到的 404 是框架页面而非 S3 错误，极难从错误码反推。所以：① `parseEndpoint` 的 `basePath`
一路传到驱动的 `_requestPath`；② 路径拼装抽成 `drivers/s3_path.dart` 的纯函数并单测
（子路径 / path-style / 目录补斜杠 / 编码）；③ `x-amz-copy-source` 不带前缀——它是桶内语义。

**ADR-21 单实例用「端口区间 + 握手」，而不是固定端口**
固定端口 + 绑定失败即退出，遇到「47913 被别的程序占用」时表现为「双击 exe 什么都不发生」，
比多开一个实例更难排查；而且同一客户端装两个版本时也会互相顶掉。改成：先逐个端口握手
（`nimbo:show` → 回 `nimbo`），确认是 Nimbo 才认领；再绑定区间内第一个空闲端口；
整段都不可用则放弃保护但正常启动。代价：极端情况下可能同时跑两个实例（可接受，
比打不开强），且握手协议本身是明文回环通信（无敏感信息）。

**ADR-22 右键菜单用「原生触发器优先 + 手动弹出兜底」**
`tray_manager 0.8` 的兼容层不会设置 `ContextMenuTrigger`（默认 `None`），导致右键只发事件、
不弹菜单。修法有三种：① 升级到 nativeapi 原生 API 自己管菜单；② 在 `onTrayIconRightMouseDown`
里手动 `popUpContextMenu()`；③ 给现有托盘图标补 `setContextMenuTrigger(rightClicked)`。
选 ③ 为主、② 为兜底：③ 是原生路径，菜单定位/前台窗口/键盘导航都由平台处理，
不需要在 Dart 侧抢时序；② 依赖「在点击回调里同步调用 `TrackPopupMenu`」，菜单的点击回调
会嵌在事件回调里派发（嵌套 native→Dart），可靠性差一些，只作为老版本 nativeapi 的保险。
两者必须互斥，否则同一次右键会弹两次菜单。

**ADR-23 并发默认值改动要区分「用户选过」与「默认写入」**
设置项一旦落盘，就分不清「用户显式选了 2」和「旧版本把默认值 2 写进去了」，
直接改默认值对老用户等于没改。所以加一个 `maxConcurrentPinned` 标记：设置页的芯片
点击时才置 true，`load()` 里只有 pinned 才采纳历史值，否则用新默认值 3。
代价是多一个持久化字段；换来的是「改默认值立刻对存量用户生效，也不会覆盖用户的选择」。

**ADR-24 下载目录用「写探针 + 静默回落」，不做强制校验**
用户配的目录可能被删、被策略限制、或被替换成同名文件。保存时强制校验会在
「临时拔了移动硬盘」这类场景直接挡住保存；完全不校验又会让下载在入队时炸。
折中：保存时只存路径（`updateSettings` 不碰文件系统），`downloadDir()` 真正要写时
建目录 + 写一个空探针文件，失败就回落到默认目录。这样下载永远能进行，
只是位置可能不是用户以为的那个——比失败可接受。

**ADR-25 Windows 界面字体用系统 Arial，不打包字体**
先试过内置思源黑体（Noto Sans SC 400/500/700，+24 MB）：能保证字形一致，但代价是包体
膨胀，且只带三个字重时界面里密集的 w600/w700 都被映射到 500/700，观感偏粗。
改为系统 Arial：零体积、Windows 全版本自带、拉丁笔画更细；代价是**中文不受控**
（Arial 无 CJK，只能靠 `fontFamilyFallback` 落到雅黑），中英混排时两种字族的
字面大小需要靠视觉确认，不能指望「整段都是 Arial」。
结论：宁可接受中英分别用 Arial / 雅黑，也不要把 24 MB 字体塞进安装包。

**ADR-26 多挂载用「每挂载一条常驻会话」，不引入全局 VFS**
OpenList 的做法是真正的虚拟文件系统（一个根下挂多个存储、统一路径空间）。本次只做
「连接常驻 + 按需建立」，不改路径模型：文件页仍是「全部挂载聚合根 → 进入某个挂载」，
只是切换不再断开别的挂载。好处是改动局限在 `AppState` 与两个页面，风险可控；
代价是跨挂载的「统一浏览 / 拖拽」仍然没有（要做得先有 VFS 层）。
如果以后要做 VFS，`sessionFor()` 已经是一个现成的连接池，可以直接复用。

**ADR-27 复制默认走「临时文件中转」，而不是为每个协议手写服务端复制**
服务端复制（S3 `CopyObject`、SFTP `copy-data`）更快，但每加一个协议就要多写一份易错代码，
而且跨挂载时无论如何都要中转。所以默认实现放在基类（下载→上传），只在**明显划算且低风险**的
协议上覆写（本地的 `File.copy`、WebDAV 的 `COPY`）。大文件跨挂载复制会经过本地磁盘，
这是已知成本，后续按需给 S3 补 `CopyObject`。

**ADR-28 Windows「下载」目录读注册表，不写死用户目录**
`%USERPROFILE%\Downloads` 只是默认值，用户改过位置（D 盘、OneDrive）后它就是错的。
注册表 `User Shell Folders` 的下载 GUID 才是系统真值，值是 `REG_EXPAND_SZ`（可能含
`%USERPROFILE%`），必须展开后再用。查不到才回落默认路径——这条兜底保证精简系统也能用。

---

## 5. 注意事项与已知坑（必读）

1. **不许本地编译。** 唯一可信的编译结果是 Actions。本地只做静态自查（改完可以 grep/读代码，别试着 `flutter build`）。
2. **推送可能失败。** 本机代理到 `github.com` 的 git 通道偶尔 502；`api.github.com` 仍可用。
   遇到 `CONNECT tunnel failed` / `HTTP2 framing layer` 就换 `tools/push_via_api.py`。
3. **改平台配置要改 workflow。** `android/`、`windows/` 被 `.gitignore` 忽略，改了也进不了仓库。
4. **file_picker 是 8.x，API 与 13.x 完全不同。** 8.x：`FilePicker.platform.pickFiles()` 返回
   `FilePickerResult?`；13.x：`FilePicker.pickFiles()` 直接返回 `List<PlatformFile>`，
   `size` 改成 `await file.length()`。升级时这两个调用点（`files_page.dart` 的 `_upload`）必须一起改。
5. **Android 上 file_picker 返回的是缓存副本路径。** 大文件会额外占一倍存储空间；
   真正的 SAF 直读需要改用 `PlatformFile.readAsByteStream()` 并让驱动接受 Stream。
6. **上传中断的远端残留要看协议（P4 已改）。**
   S3 分片：状态落盘、**不再 Abort**，下次按分片表续传（见 ADR-14）；
   FTP/SFTP/本地：续传依赖「远端大小 == 记录偏移」，不一致就整份重传并覆盖；
   WebDAV：写 `*.nimbo-part` 再 MOVE，正式路径不会被写坏，但异常退出可能留下临时文件。
   **别假设「暂停一定续传」**，以 `driver.resume` 为准。
7. **FTPS 尚未实现。** `models.dart` 里 FTP 的 hint 写着「明文 / FTPS」属于文案超前，
   实际只有明文 FTP。要么实现 `AUTH TLS`，要么把文案改成「明文 FTP」。
8. **`total` 未知时的进度（P4 已修）。** FTP 无 SIZE 时 `total = 0`，现在
   `TransferTask.indicatorValue` 返回 null，进度条画不确定态、百分比显示「—」。
   新增进度展示时请用 `indicatorValue`，不要直接用 `progress`（会停在 0%）。
9. **S3 目录删除已分页（P3 已修）。** `removeEntry` 用 `IsTruncated` +
   `NextContinuationToken` 循环删除；超大目录仍是一个键一次 DELETE，耗时随对象数增长。
10. **挂载页已支持单挂载「测试连接」与「编辑」（P4 已修）。** 凭据取自已保存的安全存储；
    编辑时密码留空表示不修改，且不允许换协议（凭据语义不同）。
11. **凭据在系统安全存储里，不写 prefs.json。** Windows 便携版换机器/重装系统后凭据会丢，
    需要重新输入；这是有意的（配置可备份，密码不落盘）。
12. **浏览会话与传输各用各的连接。** `AppState._driver` 只服务浏览；
    切换挂载不会中断传输，这是设计如此，别把两者合并成单例。
13. **代理只做隧道，不改 Host。** S3 的 SigV4 把 `host` 签进去了，
    反向代理改写路径或 Host 必然 `SignatureDoesNotMatch`——文档里明确不支持这种部署。
14. **进度回调是中断点。** 写新驱动时若在长循环里不调用 `onProgress`，暂停按钮对该协议无效；
    同时注意在 `finally` 里关闭 sink/handle，否则中断会泄漏。
15. **`analyze` 是唯一门禁，一次只改一类问题。** 本地没有 Flutter SDK，`dart analyze` 也跑不了，
    所以提交粒度要小：`analyze` 约 1.5 分钟出结果，platform 构建要 5–6 分钟，混改会让定位成本翻倍。
16. **本机直连 `github.com` 需要两件事**（否则 90 秒后报 `GnuTLS recv error (-110)`）：
    ① `/etc/hosts` 固定一个可用 IP（`~/.user_hosts` 里也要写，否则重启丢失）；
    ② `ip link set eth0 mtu 1400`（PMTU 黑洞，改完 `git ls-remote` 从 37 s 降到 1.2 s）。
    另外 `git -c http.version=HTTP/1.1` 必须生效（全局已配），GnuTLS 走 h2 会握手失败。
17. **Actions 产物下载走 Azure Blob，单连接只有约 15 KB/s。** `gh run download` 会卡十几分钟；
    实际做法是取 302 的签名 URL，用 16 路 `curl -r` 分块并发，9 MB 约 1 分钟、13 MB 约 1.6 分钟。
    注意 SAS 有效期只有 10 分钟，**下载前现取 URL**；且只能交给 curl，urllib 跟随 302 会
    重新编码查询串导致 403。
18. **`flutter create` 生成的 release `AndroidManifest.xml` 不含 INTERNET 权限。**
    只有 `src/debug` 与 `src/profile` 的 manifest 带权限，release 包因此没有任何网络能力：
    FTP/SFTP/S3/WebDAV **全部**登录失败，而本地挂载正常。CI 的 `grant network permissions`
    步骤负责注入 `INTERNET` / `ACCESS_NETWORK_STATE` 与 `usesCleartextTraffic="true"`
    （Android 9+ 默认禁明文 HTTP，WebDAV `http://` 会被拦）。**这三项不要从 workflow 里删**，
    删了就会重现「四个协议都登不上」。校验方式：解包 APK 读 `AndroidManifest.xml` 的字符串池。
19. **dio 的 `fetch(RequestOptions)` 不会合并 `BaseOptions.headers`。**
    WebDAV 的 `Authorization` 是在 `BaseOptions.headers` 里统一设置的，用 `_dio.fetch`
    发 PROPFIND 时认证头会丢，服务器一律回 401 —— 表现为「别的客户端能登，本应用登不上」。
    所有自定义方法（PROPFIND / MKCOL / MOVE / HEAD）必须走 `_dio.request(url, options: Options(method: ...))`。
    **新增 WebDAV 方法时不要再用 `fetch(RequestOptions)`。**
20. **`tray_manager 0.8` 的 0.5 兼容层会丢弃 `DoubleClicked`。**
    `legacy.dart` 的 `_wireTrayEvents` 只把 `TrayIconClickedEvent` 重放成 down+up，
    `TrayIconDoubleClickedEvent` 直接 `break`。所以「双击显示窗口」不能只靠
    `onTrayIconMouseDown` 的时间差，还要 `trayManager.trayIcon?.addListener(...)`
    直接监听底层事件兜底。两条路都保留，任一命中即可。
21. **Windows 产物必须整包分发。** 新版 tray/window 走 `nativeapi`，依赖同目录的
    `cnativeapi.dll`、`window_manager_plugin.dll`、`screen_retriever_windows_plugin.dll`。
    只拷 `nimbo.exe` 会在启动或建托盘时崩。CI 的 portable zip 已经把它们都打进去了。
22. **便携凭据是混淆不是加密。** `userdata/credentials.dat` 用固定密钥 XOR + base64，
    目的是「整个目录拷到别的机器密码还在」，不防本机其他程序。同机上仍优先系统凭据库
    （DPAPI），便携文件只是备份。不要把这条写成「加密存储」。
23. **单实例用回环端口 47913。** 若该端口被其他程序占用，第二个 Nimbo 也会直接退出
    （宁可少开一个实例，也不要出现两个写同一份 prefs 的进程）。换端口时同步改
    `lib/platform/single_instance.dart` 里的常量。
24. **返回键用 `canPop: false` 全接管。** 任何新增的全屏路由（如自己 push 的页面）都要
    在 `PopScope` 之外单独处理返回，否则会一路回退到文件页而不是关闭该页面。
25. **限速的取令牌点必须和 `onProgress` 在同一个循环里。** 令牌桶是全局单例
    （`TransferLimiter.instance`），驱动在自己读写循环里 `await bucket.take(n)`；
    dio 的 `onSendProgress` 是同步回调，**不能**在里面限速，只能整条流用
    `throttleStream()` 包一层（WebDAV 上传就是这么做的）。新增驱动漏了这一步，
    该协议就不会被限速。
26. **S3 分片状态最多留 7 天**（`MultipartStore.maxAgeDays`），且只有「文件大小 + 分片大小
    都对得上」才复用；否则当作没有，重新 Initiate。ETag 必须原样进 Complete，
    所以别把状态里的 `parts` 只当进度用。
27. **S3 的 uploadId 与本地记录可能不一致。** 续传前一定先 `ListParts` 以服务端为准：
    本地记着 20 片、服务端被 lifecycle 清空的情况真实存在，直接信本地会 Complete 失败。
28. **`userdata/multipart.json` 是隐藏的中间状态。** 换机器/删目录后旧的 uploadId 就找不到了，
    表现为「续传变成整份重传」——这是预期行为，不要试图猜 uploadId。
29. **`setPreventClose(true)` 之后必须自己处理 `onWindowClose`。** 只 hide 不拦截、
    或只拦截不 hide，都会出现「点了 × 窗口没了但托盘还在 / 托盘点了没反应」。
30. **恢复的传输任务要用「挂载对象」而不是 id。** `TransferManager.restore(saved, mounts)`
    会把挂载登记进 `_mounts`；编辑挂载后要 `syncMount()`，否则任务会拿旧地址去连。
31. **WebDAV 的 partial PUT 必须用「总长度」自校验。** 有些服务器对 `Content-Range`
    不报错、直接把这半段当成整份写进去；只看状态码会得到一个长度不对却「成功」的文件。
    `_putRange` 里的 `sizeOf(temp) == length` 是唯一可信的判据。
32. **WebDAV 断点必须绑定「大小 + mtime」。** 只记长度会让同名同长度的另一个文件
    拿别人的前缀拼接。文件被 touch 过会丢续传资格 —— 这是有意的失败方向。
33. **移动端新增固定尺寸必须用 `uiSize()`。** `MediaQuery` 的文本缩放只作用于文字，
    写死 `height: 30` 的按钮/行在 Android 上会把放大 1.2 倍的文字裁掉。
    同理：新增 `Row` 里的长文本要放进 `Expanded`/`Flexible`，否则窄屏 + 放大字号必溢出。
34. **不要用 `const` 包裹含 `uiSize()` 的控件。** `uiSize()` 依赖
    `defaultTargetPlatform`，不是常量，`const` 构造会直接编译失败。
35. **S3 / WebDAV 不要再加独立端口框。** 端口写在地址里，解析统一走
    `core/endpoint.dart` 的 `parseEndpoint()`；驱动里不要另写一套 `Uri.parse`，
    否则表单预览与实际连接会出现「看着是 8443、连的是 443」这种不一致。
36. **`mount.port` 对 S3 / WebDAV 恒为 0。** 显示层要判 `port > 0` 再拼（否则出现
    `dav.example.com:0`）；新增用到端口的逻辑，先看 `protocol.portInHost`。
37. **S3 的 Endpoint 可能带子路径。** 网关型部署（`https://host/s3`）里前缀是路由的一部分，
    必须拼进请求路径与 SigV4 的 CanonicalRequest；`x-amz-copy-source` 不能带它。
    看到「404 但响应不是 S3 XML」时，第一嫌疑就是前缀丢了（坑已修，`s3_path.dart` 有单测兜住）。
38. **托盘菜单会被派发两次。** `tray_manager 0.8` 的 `_onMenuItemClicked` 先调
    `MenuItem.onClick`，再调每个 listener 的 `onTrayMenuItemClick`。动作只能写一处，
    且必须幂等（`exitApp` 用 `_exiting` 挡住第二次）。
39. **托盘未就绪时不能「收进托盘」。** 图标/菜单装失败时点 × 如果还 `hide()`，
    窗口没了、托盘也没了，进程变成看不见也关不掉。`_trayReady` 就是这道闸。
40. **托盘图标按文件路径加载。** 插件把 `assets/tray.ico` 解析成
    `<exe>/data/flutter_assets/assets/tray.ico`；便携包少拷 `data/` 就没有托盘。
41. **`exit(0)` 不跑 `dispose()`。** 任何「彻底退出」的路径都要先 `flush()` 落盘，
    否则设置与传输断点会丢最后一秒。
43. **托盘右键不弹菜单，先看 `ContextMenuTrigger`。** `setContextMenu()` 只挂菜单、
    不负责显示；nativeapi 默认 `None`，必须 `setContextMenuTrigger(rightClicked)`
    （读回确认生效）。这是「图标在、左键有反应、右键毫无响应」的标准成因。
44. **右键菜单的两条路径不能同时开。** 原生触发器生效时 `onTrayIconRightMouseDown`
    必须为空，否则会弹两次（第二次会立刻关掉第一次）。
45. **菜单点击回调在 `TrackPopupMenu` 的栈里。** 退出前不能立刻
    `trayManager.destroy()`，否则会被 `Menu::Open()` 用到的菜单对象已被释放
    （use-after-free）；`exitApp()` 里先 `await 60ms` 让原生栈解开。
46. **`readOnly` 已彻底移除。** 老 `prefs.json` / `transfers.json` 里可能还有这个键，
    但 `Mount.fromJson` 不再读、`toJson` 不再写。**不要再加回来**：权限差异应该由
    服务端返回的错误（403）体现，客户端开关只会让人以为「设了只读就安全」。
47. **并发默认值是 3，但老用户可能仍是 2。** 只有设置页点过芯片（`maxConcurrentPinned`）
    才保留历史值；新增设置项如果要改默认值，请照这个模式加 pinned 标记。
48. **下载目录只对新任务生效。** `localPath` 在入队时算好并落盘，改设置不会迁移
    已在队列里的任务；想让新目录生效，下载新文件即可。
49. **字体名 ≠ 字体可用，但 Arial 是例外。** `fontFamily: 'Source Han Sans SC'` 在没装该字体的
    Windows 上不报错也不警告，只静默回落；Arial 则各版本 Windows 都自带（`arial.ttf`），
    可以放心写死。换字体时**必须**确认是系统核心字体，否则要先验证再上。
50. **组件主题的 `textStyle / titleTextStyle` 不继承 `textTheme`。** 换字体必须一起改，
    否则「大部分地方变了、AppBar 标题和 Tooltip 没变」，这种半生效最难发现。
51. **Arial 没有中文字形。** 中文靠 `fontFamilyFallback` 的雅黑，链里雅黑必须排在
    `Segoe UI` 前面；删掉回落链会让中文落到系统字体链接，出现同界面多字族混排。
52. **会话是「每挂载一条」，不要再写单例 `_driver`。** 需要访问非当前挂载的代码一律用
    `AppState.sessionFor(mount)`（复用/按需建立），用完**不要** close——关掉会让该挂载
    从「已连接」掉线，下次又要重新握手。
53. **改挂载配置必须 `dropSession`。** 旧会话里是旧主机/端口/凭据，留着会出现
    「配置改了但还是连老地址」的灵异现象（`updateMount` 已处理）。
54. **复制/移动的目录不能进自己。** `copyOrMoveEntries` 只在同挂载时检查，
    跨挂载不可能递归；新增别的搬运入口时也要带上这个判断。
55. **Windows 下载目录来自注册表。** 值可能是 `%USERPROFILE%\Downloads`，必须展开；
    展开失败要回落，否则会创建出名字里带 `%` 的目录。
56. **WebDAV 中断不再删临时文件。** 以前失败就 `DELETE *.nimbo-part`，现在保留它作为
    续传载体；代价是远端会留一个 `*.nimbo-part`，下次同名上传会续传/覆盖。
    取消任务不会主动清理远端临时文件（与 S3 分片的处理一致）。

---

## 6. 待办（按建议顺序，P2/P3/P4 已完成项已移出）

### 6.0 优先修复：审查缺陷（详见 [`docs/bug-audit.md`](bug-audit.md)）

| 批 | 内容 | 说明 |
|---|---|---|
| A | BUG-01、BUG-02 | 配置并发写 / 解析失败丢挂载 —— **唯一会丢用户数据的路径**，先修并补单测 |
| B | BUG-03、04、10、11、14 | 会话去重、取消语义、连接错误被清掉、单实例 socket 超时 |
| C | BUG-05、06、07、08 | 限速除零、复制到源目录、注册表缓存、刷新节流 |
| D | BUG-09、12 | FTP/SFTP 读超时、预热与删除竞态（需真机验证暂停/取消） |
| E | BUG-13、15、16 | 本地列表异步化、WebDAV 临时文件清理、批量删除 busy 态 |

### 6.1 功能待办

| # | 事项 | 为什么 | 难度 | 主要文件 |
|---|---|---|---|---|
| 1 | **预览扩展（音视频 / PDF）** | 现在只覆盖图片与文本；`media_kit`（音视频）与 `pdfx`（PDF）都要评估包体积与 Windows/Android 两端的 native 依赖 | 高 | `preview_page.dart`、`pubspec.yaml` |
| 2 | **本地磁盘容量** | `dart:io` 没有取剩余空间的 API；`dart:ffi` 调 `GetDiskFreeSpaceExW` 可解，但要做错误兜底且只在 Windows 验证过 | 中 | 新增 `platform/disk_space.dart`、`local_driver.space()` |
| 3 | **FTPS（AUTH TLS）** | 目前只有明文 FTP。`SecureSocket.secure(socket)` 能把隧道升级成 TLS，控制连接与数据连接各要升一次（`PROT P`） | 中 | `ftp_driver.dart` |
| 4 | **传输任务级限速** | 现在是全局桶；单任务限速需要每个任务一个桶，并在 `TransferTask` 里持久化 | 中 | `limiter.dart`、`transfer_manager.dart` |
| 5 | **S3 分片状态的可视化清理** | 现在只能等 7 天过期；设置页给个「清理未完成的分片上传」按钮更直观（需要 `ListMultipartUploads`） | 低 | `multipart_store.dart`、`settings_page.dart` |
| 6 | **FTPS/明文 FTP 文案** | `models.dart` 的 hint 已改为「明文 FTP」，实现 FTPS 后记得同步改回 | 低 | `models.dart` |

## 7. 后续工作建议

1. **先把「回归」补上**：P0–P4 全部只验证到「双端编译 + analyze + 单测」，
   没有一个协议在真机/真服务端跑过。第 8 节那张表才是真正的验收，先跑它。
2. **再做 1（音视频/PDF 预览）**：用户感知最强的一项。注意 `media_kit` 会显著增大
   Windows 产物（libmpv）与 APK 体积，先量一下再决定是否只做音频 + PDF。
3. **然后 2 + 3（本地容量 / FTPS）**：都属于「协议能力补齐」，改动局限在单个驱动。
4. **最后 5（任务级限速）**：产品化收尾，依赖设置页的输入组件。
5. 每个阶段结束都：CI 三绿 → 下载产物 → 按附录回归 → 更新本文档的「当前阶段」表与「构建记录」。

**给下一位 AI 的工作方式（重要）**：

- 先读第 0、1、5 节，再看要改的那一节；**不要从头读全部源码**，`lib/` 只有约 6 千行但跨 5 个协议。
- 改动前先 `grep` 现有调用点（`downloadTo` / `uploadFile` 的签名一变，五个驱动都得跟着改）。
- 提交粒度：一个能力一个 commit。`analyze` 失败时 `gh run view --job <id> --log-failed` 只看带 `•` 的行。
- 本地无法编译是硬约束，**不要为了"先跑一下"去装 Flutter SDK**；靠读代码 + analyze 反馈迭代。
- 平台构建失败大多是 Gradle/PowerShell 侧（compileSdk、插件），优先怀疑依赖而不是业务代码。

---

## 8. 附录：手工回归清单

| 场景 | 步骤 | 期望 |
|---|---|---|
| 冷启动 | 首次运行 | 空状态引导，可进入「添加挂载」 |
| 本地挂载 | 选一个本地目录 | 能列、能建文件夹、能上传下载 |
| WebDAV | 坚果云/Nextcloud → 添加 → 测试连接 | 显示条目数；能列目录 |
| S3 | MinIO path-style | 能列、能传 >8 MB（走分片）、能删 |
| 代理 | 给某个挂载配 HTTP 代理后断开代理 | 报「代理不可达」，另一个挂载直连不受影响 |
| 队列 | 同时下 3 个文件 | 按并发数排队，其余显示「排队中」 |
| **续传（本地/SFTP）** | 传大文件，50% 时暂停 → 继续 | 从断点接着传，进度不回零；卡片显示「可从 xx 续传」 |
| **续传（WebDAV 下载）** | 同上 | 服务器返回 206 时续传；返回 200 时静默从头重下且文件不损坏 |
| **续传（WebDAV/S3 上传）** | 同上 | 明确整份重传（不报错、不产生错位文件） |
| **多选批量** | 「选择」→ 全选 → 下载 | 全部入队；文件夹递归展开到本地同名目录 |
| **批量删除** | 选 2 个文件 + 1 个文件夹 → 删除 | 三项都消失；失败项有汇总提示 |
| **目录上传** | 「上传 → 上传文件夹」 | 远端目录结构与本地一致 |
| **拖拽上传** | 从资源管理器拖 2 个文件到列表区 | 悬停出现高亮，松手后入队 |
| **预览** | 点图片 / .md 文件的「预览」 | 图片可缩放；文本等宽可选中；>24 MB 图片提示下载 |
| 上传刷新 | 上传完成后看列表 | 新文件自动出现 |
| 切挂载 | 传输中切换挂载 | 传输继续，列表切到新挂载 |
| 断网 | 传输中断网 | 状态转「失败」并给出可读原因，不是崩溃 |
| **FTP 匿名** | 添加 FTP 时勾选「匿名登录」 | 用户名/密码置灰；能列出匿名目录 |
| **返回键** | 依次按返回：子目录 → 挂载根 → 全部挂载 → 提示 → 再按 | 前三次逐级回退，最后一次连按两次才退出 |
| **传输记录** | 传一半 → 杀进程 → 重开 | 任务列表还在，状态是「已暂停」，点继续能从断点接着传 |
| **托盘左键单击** | 左键单击托盘图标 | **无任何响应**（窗口不动、不聚焦、不闪烁）；连续单击多次也一样 |
| **托盘右键** | 右键托盘图标 | 立刻弹出菜单（含「显示主窗口」「退出」）；点击菜单外区域能正常关闭；菜单不会只闪一下就消失 |
| **托盘菜单项** | 右键托盘图标 | 菜单只有「显示主窗口」「退出」两项（中间分隔线）；点「显示主窗口」窗口出现并聚焦；点「退出」进程消失、托盘图标消失 |
| **托盘双击** | 左键双击 | 只执行一次显示+聚焦（300ms 去重生效，不闪两次） |
| **悬停提示** | 鼠标停在托盘图标上 | 出现提示文字「Nimbo」 |
| **右键触发器诊断** | 启动后看调试输出 | 出现「Nimbo: 托盘就绪（右键菜单触发方式：原生）」；若显示「手动兜底」则右键应仍能弹菜单 |
| **单实例** | 程序在后台（已收进托盘）时再双击 exe | 不出现第二个进程；已有窗口被唤到前台；第二进程立即退出 |
| **单实例（端口被占）** | 先用别的程序占住 47913，再启动 Nimbo | 仍能正常启动（换到 47914），不静默退出 |
| **退出落盘** | 传一半 → 托盘「退出」→ 重开 | `userdata/transfers.json` 里能看到断点状态，任务恢复为「已暂停」 |
| **托盘不可用** | 临时把 `assets/tray.ico`/`tray.png` 移走再启动，点 × | 进程直接退出（不会藏成僵尸）；调试输出里有「托盘初始化失败」 |
| **关闭到托盘** | 设置里打开「关闭窗口时收进托盘」→ 点 ×；再从托盘双击 | 进程不退出，窗口隐藏；托盘双击后窗口恢复并聚焦 |
| **直接退出** | 关掉「关闭窗口时收进托盘」→ 点 × | 进程退出；托盘图标消失 |
| **限速** | 设置里下载限速 512 KB/s → 下一个大文件 | 速度稳定在 500 KB/s 上下；改成 0 后恢复满速 |
| **SFTP 容量** | 打开 SFTP 挂载 | 标题出现「剩余 xx GB」；服务器不支持 statvfs 时不显示该项 |
| **S3 子路径 Endpoint** | Endpoint 填 `https://demo.foxel.cc/s3`、桶 `jsjej66`、path-style、AK/SK 正确 | 能列出桶内对象（请求路径为 `/s3/jsjej66/...`）；若仍 404，错误文案会提示「可能漏了路径前缀」 |
| **S3 端口在地址里** | 添加 S3，Endpoint 填 `https://minio.local:9000` | 没有端口框；预览显示「端口 9000（地址中指定）」；能列目录 |
| **WebDAV 端口在地址里** | 添加 WebDAV，地址填 `https://dav.example.com:8443/dav` | 预览显示端口 8443 与基础路径 `/dav`；能列目录 |
| **非法地址校验** | 地址填 `ftp://host` 或 `https://`，点「测试连接」与「保存」 | 两处给出同一条可读错误（只支持 http/https / 缺主机名），不会保存 |
| **FTP/SFTP 端口框** | 添加 FTP，端口填 `abc` / `99999` | 提示「1–65535」；改成空则用 21/22，正常保存 |
| **编辑老配置不丢端口** | 用旧版本保存过一个 `host=example.com / port=8443` 的 WebDAV 挂载，再打开编辑 | 地址自动变成 `https://example.com:8443`，保存后仍能连 |
| **界面字体（拉丁）** | Windows 启动后看「Nimbo」「FTP」「S3」「KB/s」 | 拉丁字母是 Arial 的细笔画，与改前相比明显变细 |
| **界面字体（中文）** | 看「独立代理」「添加挂载」 | 中文仍是雅黑，无豆腐块；不要期待中文变 Arial（Arial 无 CJK） |
| **字体回落** | 文件名改成 `𠮷🙂测试.txt` 再浏览 | 不出现豆腐块（走 `Microsoft YaHei UI` / `Segoe UI` 回落） |
| **字体不改变布局** | 对比换字体前后的文件列表与详情栏 | 行高与换行位置基本一致，表格列宽没被撑开 |
| **托盘双击 = 菜单「显示主窗口」** | 先收进托盘：分别用双击和右键菜单项唤回 | 两者表现完全一致（显示 → 还原 → 聚焦），没有「一个能用一个不能」 |
| **下载目录跟随系统** | 把 Windows「下载」位置改到 D 盘 → 下载一个文件 | 落在 `D://...//Nimbo`，不是 `C://Users//<你>//Downloads//Nimbo` |
| **多挂载同时在线** | 挂 2 个不同协议 → 轮流点开 | 切换立刻出列表（无握手等待）；两张卡片状态点都是绿色「已连接」 |
| **挂载失败隔离** | 把其中一个挂载的密码改错 → 重启 | 只有那张卡片显示「未连接」，其它挂载正常，启动不受影响 |
| **同挂载复制** | 选中文件 → 更多 → 复制到… → 同挂载另一目录 | 源还在，目标出现同名文件；提示「已复制 1 个文件到 …」 |
| **同挂载移动** | 同上，选「移动到…」 | 源消失、目标出现；目录整体移动（不逐文件拷） |
| **跨挂载复制** | A 里选中文件 → 复制到… → 选挂载 B 的目录 | B 出现同名文件；A 的文件保留 |
| **复制进子目录被拦** | 选中目录 → 复制到… → 选它自己或子目录 | 提示「不能把「xxx」放进它自己或它的子目录」，不执行 |
| **Windows 无挂载切换器** | Windows 启动，看侧栏顶部 | 没有「未选择挂载 / 点击选择」下拉；直接是导航 + 挂载列表；点列表项能正常切换挂载 |
| **平板仍有切换器** | 安卓平板（宽 ≥900 px）打开应用 | 侧栏顶部仍有挂载切换器，行为与之前一致 |
| **弹窗代理行不溢出** | 安卓打开添加挂载 → 打开「独立代理」 | 只有开关 +「独立代理」，右侧没有说明文字，不出现横向溢出条纹 |
| **弹窗底部按钮居中** | 同上，看底部按钮 | 「测试连接」「保存并连接」相对弹窗水平居中，左右留白相等，不贴右边界 |
| **挂载卡片布局** | Windows 打开挂载管理 | 信息在左三行、四个按钮在右且垂直居中；四个按钮同高 28；删除在最右、浅红底红字，与「打开」之间有竖分隔线 |
| **窄屏卡片** | 手机打开挂载管理 | 按钮组换到信息区下一行、右对齐，删除仍在最右 |
| **名称默认空** | 打开添加挂载弹窗 | 「显示名称」是空的，没有预填任何文字 |
| **名称空值被拦** | 其余字段填对，名称留空 → 点保存 | 不创建；提示「显示名称不能为空，请填写一个便于识别的名字」；「测试连接」同样被拦 |
| **名称纯空格被拦** | 名称只输入 3 个空格 → 点保存 | 不创建；提示「显示名称不能只填空格，请填写有效字符」 |
| **编辑时清空名称** | 编辑已有挂载 → 清空名称 → 保存 | 不保存；同样的必填提示 |
| **桌面返回上层** | Windows 进任意挂载的子目录 → 点「返回上层」 | 回到上一级；在挂载根再点 → 回「全部挂载」聚合视图；停在聚合根时按钮置灰 |
| **移动端无该按钮** | 安卓手机打开文件页 | 标题行只有「上传 / 新建」，没有「返回上层」；系统返回键行为不变 |
| **数据卡片已移除** | 打开设置页 | 没有「数据目录 / 存储方式 / 配置文件」那一块；页面只剩主题、传输、桌面（Windows） |
| **下载目录默认值** | Windows 下载一个文件；Android 下载一个文件 | Windows 落在「下载\Nimbo」，Android 落在 `内部存储/Download/Nimbo`（11+ 未授权时落应用私有目录，不报错） |
| **设置页提示已移除** | 打开设置页 | 并发任务右侧没有说明文字；桌面卡片只有托盘开关；「安全」「关于」两张卡片整体消失，页面到底即结束 |
| **点文件默认隐藏** | 删掉 `userdata/prefs.json` 后启动，进一个有 `.git` 的目录 | 默认看不到 `.` 开头的条目；关掉「隐藏以「.」开头的文件」后立刻出现 |
| **只读开关已移除** | 打开添加/编辑挂载弹窗 | 表单里没有「只读挂载」；文件页的上传/新建/删除/重命名/拖拽全部可用，不再有只读门禁 |
| **弹窗底部提示已移除** | 同上，看弹窗底部 | 只剩「测试连接 / 保存」按钮，没有「凭据只写入系统安全存储…」那段文字 |
| **下载目录** | 设置 → 下载目录 → 选择 `D://Media` → 下载一个文件 | 文件落在 `D://Media`；重启后设置仍在；把该目录删掉再下载 → 自动回落到 `下载/Nimbo`，不报错 |
| **并发默认 3** | 删掉 `userdata/prefs.json` 后启动 → 设置页 | 并发任务高亮在 3；手动选 2 后重启仍是 2（`maxConcurrentPinned` 生效） |
| **挂载测试连接** | 挂载页对某个挂载点「测试连接」 | 成功显示「根目录 N 项」；失败显示带建议的原因，且不影响已保存配置 |
| **编辑挂载** | 挂载页「编辑」→ 只改显示名 → 保存 | 名称立即变；密码不用重输；正在浏览该挂载时自动重连 |
| **WebDAV 原子上传** | 传大文件到 WebDAV，传一半暂停 | 正式文件不存在（或仍是旧版本）；目录里最多留一个 `*.nimbo-part` |
| **WebDAV 上传续传（支持 partial PUT 的服务器）** | 传大文件到 SabreDAV/Nextcloud，60% 暂停 → 继续 | 从 `*.nimbo-part` 的实测长度续写；完成后 `MOVE` 成正式名，内容完整 |
| **WebDAV 上传续传（不支持的服务器）** | 同上，但服务器返回 400/501 或忽略 `Content-Range` | 进度回到 0、整份重传；结束文件内容正确（不出现错位文件） |
| **S3 分片续传** | 传 100 MB+ 到 S3，60% 时暂停 → 继续 | 从已完成分片处继续，不从头传；`userdata/multipart.json` 有对应记录，完成后消失 |
| **S3 分片并发** | 传 200 MB 到 MinIO | 3 条 PUT 并行（看服务端日志/网络），总时长明显短于串行 |
| **错误文案** | 把某个挂载端口改成错的 → 打开 | 提示里除了协议错误，还有一句「检查主机与端口是否可达」这类建议 |
| **单实例** | 程序已开，再双击 exe | 不出现第二个进程；已有窗口被唤到前台 |
| **便携** | 整个文件夹换到另一台机器 | 挂载配置与密码都还在（`userdata/` 随目录走） |

> 上表是**建议的**回归用例。本轮仍只验证到「双端编译通过 + `flutter analyze` 零问题」，
> 没有真机/真服务端跑过（本机不装 Flutter、也没有测试用的 FTP/S3/WebDAV 服务）。
> 第一次拿到产物的人应当把这张表跑一遍，并把结果补回到本文档。

---

## 9. 构建记录

| 时间 | 提交 | analyze | windows-x64 | android-arm64 | 说明 |
|---|---|---|---|---|---|
| 2026-10-23 16:30 | `d405983` | ✅ | ✅ | ✅ | P0 骨架首次双端通过 |
| 2026-10-23 16:53 | `ab3d1ba` | ❌ | — | — | `writeBytes` 需要 `Uint8List`（用 `openRead()` 的 `List<int>` 直接传） |
| 2026-10-23 16:58 | `bec26fa` | ✅ | ✅ | ❌ | `file_picker 8.x` 写死 `compileSdk 34`，与 lifecycle 要求的 36 冲突 |
| 2026-10-23 17:08 | `c40180a` | ✅ | ✅ | ✅ | **P1 完成**：抬 compileSdk 后双端通过 |
| 2026-10-23 22:05 | `4e4d743` | ✅ | ✅ | ✅ | P2-1：多选批量、文件夹上传、图片/文本预览 |
| 2026-10-23 22:20 | `f304f7b` | ✅ | ✅ | ✅ | P2-2：断点续传（下载全协议 / 上传 FTP+SFTP+本地） |
| 2026-10-23 22:22 | `f7f9515` | ❌ | — | — | `desktop_drop 0.9.2` 与 `file_picker 8.x` 的 `cross_file` 冲突，pub 求解失败 |
| 2026-10-23 22:25 | `8e8bb7d` | ✅ | ✅ | ✅ | P2-3：降到 `desktop_drop 0.8.4`，拖拽上传通过双端 |
| 2026-10-23 22:35 | `0237274` | ✅ | ✅ | ✅ | **P2 完成**：目录下载 + 版本 `0.3.0+3` |
| 2026-10-23 23:20 | `8e7203e` | ✅ | ✅ | ❌ | 补 Android 网络权限；android 失败于 runner 下载 NDK 损坏（`Error on ZipFile unknown archive`），非代码问题 |
| 2026-10-23 23:25 | `a2270c1` | ✅ | ✅ | ✅ | 同上，重跑后三绿：release APK 已含 `INTERNET` + `usesCleartextTraffic` |
| 2026-10-24 05:45 | `8e09e26` | ✅ | ✅ | ✅ | **WebDAV 401 修复**：PROPFIND/MKCOL/MOVE 改用 `_dio.request`，恢复 Authorization 头 |
| 2026-10-24 06:02 | `b5f1851` | ✅ | ✅ | ✅ | 文件页根改为「全部挂载」聚合视图（`browseAll`），不再只渲染单个挂载 |
| 2026-10-24 06:30 | `99c48e4` | ✅ | ✅ | ✅ | P3-1：FTP 匿名、返回键逐级回退、S3 目录分页删除、长按多选 |
| 2026-10-24 06:36 | `67431e8` | ✅ | ✅ | ✅ | P3-2：传输记录持久化（`transfers.json`，恢复为已暂停） |
| 2026-10-24 07:05 | `8b56751` | ✅ | ✅ | ✅ | P3-3：Windows 托盘/单实例/便携凭据 + 返回连按两次退出（新增 tray_manager、window_manager） |
| 2026-10-24 08:10 | `19db18b` | ✅ | ✅ | ✅ | 设置页补齐 + 版本号单一来源 + 错误文案统一 + 未知大小不确定进度 |
| 2026-10-24 08:13 | `1353b01` | ❌ | — | — | 令牌桶 `TokenBucket(this.rate)` 命中 setter（not_initialized_non_nullable_instance_field）；S3 查询串传了 `String?` |
| 2026-10-24 08:16 | `bbe4d93` | ✅ | ✅ | ✅ | **P4 双端通过**：限速/SFTP 容量/挂载测试与编辑/WebDAV 原子上传/S3 分片续传 |
| 2026-10-24 08:20 | `45e3c72` | ❌ | — | — | analyze 通过，新增的 `flutter test` 步骤失败：cnativeapi 的 native assets 需要 gtk+-3.0 / x11 / xi |
| 2026-10-24 08:24 | `37e87f0` | ✅（含单测） | — | — | 测试前补装 `libgtk-3-dev libx11-dev libxi-dev`，`flutter test` 通过（平台构建被后续提交取代，已取消） |
| 2026-10-24 08:26 | `06331cc` | ✅（含单测） | — | — | 暂停被 dio 包装时仍按「已暂停」处理 + 文档补到 P4（平台构建被取消） |
| 2026-10-24 08:31 | `75042b8` | ✅（含单测） | ✅ | ✅ | 限速行改 Wrap；**本轮双端全绿** |
| 2026-10-24 08:36 | `7653d40` | ✅（含单测） | ✅ | ✅ | **本轮最终状态**：切换挂载清空容量、本地驱动 space 能力位修正 |
| 2026-10-24 08:48 | `ffdc097` | ✅（含单测） | — | — | WebDAV 上传续传（探测式 partial PUT + 自校验 + 降级）；平台构建被后续提交取代 |
| 2026-10-24 08:55 | `e3ede8f` | ❌ | — | — | Android 字号 1.2 倍：`defaultTargetPlatform` 未导入（material 不透出） |
| 2026-10-24 08:58 | `8707c4d` | — | — | — | 按钮高度二次放大修正（被后续提交取代，构建取消） |
| 2026-10-24 09:04 | `d40b7a3` | ✅（含单测） | ✅ | ✅ | 补 foundation 导入；**字号改动双端通过** |
| 2026-10-24 09:14 | `f0fd062` | ✅（含单测） | ✅ | ✅ | **当前最终状态**：S3/WebDAV 端口归入地址、去掉独立端口框 |
| 2026-10-24 09:31 | `957958a` | ✅（含单测） | ✅ | ✅ | S3 Endpoint 子路径修复（网关型 `/s3` 404） |
| 2026-10-24 09:45 | `845181c` | — | — | — | 文档：技术栈审查报告（docs-only，不触发构建） |
| 2026-10-24 10:03 | `75d5370` | ✅（含单测） | ✅ | ✅ | Windows 托盘/单实例/退出路径加固 |
| 2026-10-24 11:05 | `4b4a790` | — | — | — | 文档：构建记录补到 75d5370 |
| 2026-10-24 11:07 | `85720dc` | ✅（含单测） | ✅ | ✅ | 托盘右键不弹菜单修复（`setContextMenuTrigger(rightClicked)` + 手动兜底） |
| 2026-10-24 11:20 | `165f7f3` | — | — | — | 移除只读挂载/底部提示、下载目录、并发默认 3（被字体提交取代，构建取消） |
| 2026-10-24 11:29 | `2217d69` | ✅（含单测 40 项） | ✅ | ✅ | Windows 界面字体换思源黑体（内置 400/500/700）+ 上一条全部内容 |
| 2026-10-24 12:40 | `7d04c64` | — | — | — | 文档：构建记录补到 2217d69 |
| 2026-10-24 12:52 | `f5a59f6` | ✅（含单测 40 项） | ✅ | ✅ | Windows 字体改 Arial（移除内置 24MB 字体）；托盘左键单击无响应、双击与菜单项共用 `showWindow()` |
| 2026-10-24 13:08 | `25e5d01` | — | — | — | 文档：构建记录补到 f5a59f6 |
| 2026-10-24 13:15 | `2036ba3` | ✅（含单测 41 项） | ✅ | ✅ | 删除设置页说明文字；点文件默认隐藏 |
| 2026-10-24 13:25 | `5ecaf78` | ✅（含单测 41 项） | ✅ | ✅ | 删除「数据」卡片；下载目录默认值按平台（Android 公共 Download） |
| 2026-10-24 13:34 | `208b4c1` | ✅（含单测 41 项） | ✅ | ✅ | 安卓挂载弹窗两处布局修正（代理行溢出、底部按钮居中） |
| 2026-10-24 13:44 | `ce83605` | — | — | — | 文档：构建记录补到 208b4c1 |
| 2026-10-24 13:50 | `feaf088` | ✅（含单测 41 项） | ✅ | ✅ | Windows 端隐藏侧栏挂载切换器（平板保留） |
| 2026-10-24 14:15 | `7787eee` | ✅（含单测 41 项） | ✅ | ✅ | Windows 下载目录跟随系统；多挂载常驻会话；复制/移动（新增 `pick_destination.dart`） |
| 2026-10-24 14:22 | `6d9f3ff` | ✅（含单测 41 项） | ✅ | ✅ | 修 `'$base\Nimbo'` 丢反斜杠（analyze 报 unnecessary_string_escapes） |
| 2026-10-24 14:33 | `6bdec0c` | ✅（含单测 41 项） | ✅ | ✅ | 去掉插值多余花括号，analyze 回到 17 条既有 info |
| 2026-10-24 15:30 | `3d0e46f` | ✅（含单测 41 项） | ✅ | ✅ | 桌面端标题行新增「返回上层」按钮（移动端不加） |
| 2026-10-24 15:52 | `e90f8f4` | ✅（含单测 41 项） | ✅ | ✅ | 挂载卡片重排（按钮统一 28、删除常态浅红底）+ 显示名称按内容自动生成 |
| 2026-10-24 16:02 | `eac8884` | ✅（含单测 41 项） | 构建中 | 构建中 | **当前最终状态**：显示名称改为默认空 + 必填强校验（撤销自动生成）；推送时本地代理 10808 故障，改用直连 |

- 最近一次成功：commit `e90f8f4`（analyze 17 条既有 info + flutter test 41 项 + android-arm64 + windows-x64 全绿）
- `eac8884`：analyze 已通过；双端构建在审查时仍在进行（若失败，多半与本次只动 `add_mount_page.dart` 无关，优先看 diff）
- `flutter analyze` 现有 17 条 info（tray_manager legacy API 的 deprecated 提示为主），无 warning/error
- 门禁现在是两条：`flutter analyze`（约 1.5 min）与 `flutter test`（纯逻辑单测，约 1 min）
- 产物：`windows-x64-portable.zip` 12.53 MB（内含 `Nimbo.exe`）、`app-release.apk` 20.5 MB（arm64 release）
- 耗时参考：analyze ≈ 1.5 min，windows ≈ 5 min，android ≈ 6 min

**排错顺序**：先看 `analyze`（最快，绝大多数类型错误在这里就能拦住），
再抓失败的平台 job 的 `--log-failed`，只查带 `•`（Dart 侧）或 `What went wrong`（Gradle 侧）的行。
