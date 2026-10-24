# Nimbo 项目现状与交接说明

> 写给下一位接手的人或 AI。目标：读完这一篇就能继续推进，不必回溯聊天记录。
> 最后更新：2026-10-24 · P4 交付（限速 / 容量 / 挂载编辑 / WebDAV 原子落盘 / S3 分片续传）

---

## 0. 三分钟上手

| 项 | 内容 |
|---|---|
| 仓库 | `https://github.com/david88558855/Nimbo`（分支 `main`） |
| 产物 | Windows x64 便携 zip + Android arm64 APK |
| **硬约束** | **禁止本地编译**。本机没有 Flutter SDK，所有编译、静态检查、依赖解析只在 GitHub Actions 里发生 |
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

**一句话现状**：五个协议都能真实读写，上传下载都能排队跑，代理对五个协议全部生效；
大文件中断后能接着传（下载全协议；上传 FTP/SFTP/本地按远端大小续传，S3 分片按分片表续传）；
限速、托盘、关闭到托盘、单实例、便携凭据、挂载编辑与单挂载测试连接都已可用；
WebDAV 的上传也能续传（服务器支持 partial PUT 时从临时文件实测长度续写，不支持则自动整份重传）；
剩下的是音视频/PDF 预览、FTPS、本地磁盘容量这几项。

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

- 桌面（≥900 px）：236 px 导航栏（挂载切换器 / 导航 / 挂载列表 / 当前挂载的代理状态 + 只读标记）
  + 文件区（面包屑、列表、详情栏）+ 底部传输条
- **文件页根是「全部挂载」聚合视图**：`AppState.browseAll` 为真时渲染挂载卡片网格
  （名称 / 协议 / 地址 / 只读 / 代理 / 当前标记），点卡片才 `open(mount)` 进目录树；
  面包屑固定为「全部挂载 / 挂载名 / …」，第一段可随时退回。启动与删除挂载后都停在这里。
- 移动：底部四 Tab；文件页头部按钮按宽度收敛（窄屏只留「上传 / 新建」）
- 挂载页：卡片列表、移除确认、只读与代理状态展示
- 添加挂载弹窗：协议选择、动态字段（S3 多出 Bucket/Region/路径风格）、**独立代理区（标注「仅对本挂载生效」）**、连接测试；
  **S3 / WebDAV 不提供独立端口框**，端口写在地址里（见 2.11）
- 传输页：进行中/已结束分组，逐任务暂停/继续/取消，总速度汇总

### 2.7 P2 体验补齐

| 能力 | 实现要点 |
|---|---|
| 断点续传 | `StorageDriver.resume`（None/Download/Upload/Both）+ `sizeOf()`；下载起点以本地文件真实长度为准，上传起点以远端 SIZE 复核；WebDAV/S3 下载用 `Range`，只有 206 才续写，200 自动回退重下 |
| 多选批量 | `AppState` 用 `Set<String>` 按 path 记录选择；批量下载递归展开目录，批量删除串行执行并汇总失败项 |
| 目录传输 | 上传：遍历本地目录 → 保留相对层级入队；下载：广度遍历远端目录 → 本地建同名层级 |
| 拖拽上传 | `desktop_drop ^0.8.4`（0.9.x 与 file_picker 8.x 的 cross_file 冲突），只读挂载禁用 |
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
| Windows 托盘 | `lib/platform/desktop_shell.dart` + `assets/tray.ico`（脚本生成的 256px 圆角 N）。左键单击无反应、双击显示/还原/聚焦、右键菜单「显示主窗口 / 退出」 |
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

---

## 3. 文件地图

```
lib/
  main.dart                    入口：单实例 → boot() → NimboApp；Windows 首帧后初始化托盘
  app/theme.dart               设计 token（颜色/字号/圆角）+ ThemeData（单一浅色）
  core/
    models.dart                Mount / ProxyConfig / RemoteEntry / TransferTask（含 toJson/fromJson）/ 枚举与扩展
    format.dart                路径拼接与规范化、字节/速度/时间格式化、文件类型→图标与配色
    store.dart                 AppPaths（便携 userdata）、Prefs、SecureStore（系统凭据 + Windows 便携双写）
    transfer_store.dart        传输记录持久化（userdata/transfers.json，保留 60 条）
    endpoint.dart              S3 / WebDAV 地址解析（协议 / 主机 / 端口 / 基础路径），表单与驱动共用
    multipart_store.dart       S3 分片上传状态（userdata/multipart.json，含 uploadId 与分片 ETag）
    upload_checkpoint.dart     WebDAV 上传断点（userdata/uploads.json，大小 + mtime + offset）
    json_store.dart            小 JSON 状态文件的串行化读-改-写 + 原子落盘（上面两个共用）
    limiter.dart               令牌桶限速（上传/下载各一个桶 + throttleStream）
    version.dart               版本号单一来源（kAppVersion / kAppVersionLabel）
  platform/                    ← 仅 Windows 生效，Android 上全部被 Platform.isWindows 挡掉
    desktop_shell.dart         托盘图标/右键菜单/窗口显隐；单击无反应、双击显示
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
docs/s3-addressing-analysis.md S3 寻址模式与第三方兼容性分析（15 条坑）
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
37. **WebDAV 中断不再删临时文件。** 以前失败就 `DELETE *.nimbo-part`，现在保留它作为
    续传载体；代价是远端会留一个 `*.nimbo-part`，下次同名上传会续传/覆盖。
    取消任务不会主动清理远端临时文件（与 S3 分片的处理一致）。

---

## 6. 待办（按建议顺序，P2/P3/P4 已完成项已移出）

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
| **拖拽上传** | 从资源管理器拖 2 个文件到列表区 | 悬停出现高亮，松手后入队；只读挂载无反应 |
| **预览** | 点图片 / .md 文件的「预览」 | 图片可缩放；文本等宽可选中；>24 MB 图片提示下载 |
| 上传刷新 | 上传完成后看列表 | 新文件自动出现 |
| 切挂载 | 传输中切换挂载 | 传输继续，列表切到新挂载 |
| 断网 | 传输中断网 | 状态转「失败」并给出可读原因，不是崩溃 |
| **FTP 匿名** | 添加 FTP 时勾选「匿名登录」 | 用户名/密码置灰；能列出匿名目录 |
| **返回键** | 依次按返回：子目录 → 挂载根 → 全部挂载 → 提示 → 再按 | 前三次逐级回退，最后一次连按两次才退出 |
| **传输记录** | 传一半 → 杀进程 → 重开 | 任务列表还在，状态是「已暂停」，点继续能从断点接着传 |
| **托盘** | 左键单击 / 左键双击 / 右键 | 单击无反应；双击显示并聚焦窗口；右键出现「显示主窗口 / 退出」 |
| **关闭到托盘** | 设置里打开「关闭窗口时收进托盘」→ 点 ×；再从托盘双击 | 进程不退出，窗口隐藏；托盘双击后窗口恢复并聚焦 |
| **直接退出** | 关掉「关闭窗口时收进托盘」→ 点 × | 进程退出；托盘图标消失 |
| **限速** | 设置里下载限速 512 KB/s → 下一个大文件 | 速度稳定在 500 KB/s 上下；改成 0 后恢复满速 |
| **SFTP 容量** | 打开 SFTP 挂载 | 标题出现「剩余 xx GB」；服务器不支持 statvfs 时不显示该项 |
| **S3 端口在地址里** | 添加 S3，Endpoint 填 `https://minio.local:9000` | 没有端口框；预览显示「端口 9000（地址中指定）」；能列目录 |
| **WebDAV 端口在地址里** | 添加 WebDAV，地址填 `https://dav.example.com:8443/dav` | 预览显示端口 8443 与基础路径 `/dav`；能列目录 |
| **非法地址校验** | 地址填 `ftp://host` 或 `https://`，点「测试连接」与「保存」 | 两处给出同一条可读错误（只支持 http/https / 缺主机名），不会保存 |
| **FTP/SFTP 端口框** | 添加 FTP，端口填 `abc` / `99999` | 提示「1–65535」；改成空则用 21/22，正常保存 |
| **编辑老配置不丢端口** | 用旧版本保存过一个 `host=example.com / port=8443` 的 WebDAV 挂载，再打开编辑 | 地址自动变成 `https://example.com:8443`，保存后仍能连 |
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

- 最近一次成功：commit `7653d40`（analyze + flutter test + android-arm64 + windows-x64 全绿）
- 门禁现在是两条：`flutter analyze`（约 1.5 min）与 `flutter test`（纯逻辑单测，约 1 min）
- 产物：`windows-x64-portable.zip` 12.53 MB（内含 `Nimbo.exe`）、`app-release.apk` 20.5 MB（arm64 release）
- 耗时参考：analyze ≈ 1.5 min，windows ≈ 5 min，android ≈ 6 min

**排错顺序**：先看 `analyze`（最快，绝大多数类型错误在这里就能拦住），
再抓失败的平台 job 的 `--log-failed`，只查带 `•`（Dart 侧）或 `What went wrong`（Gradle 侧）的行。
