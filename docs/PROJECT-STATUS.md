# Nimbo 项目现状与交接说明

> 写给下一位接手的人或 AI。目标：读完这一篇就能继续推进，不必回溯聊天记录。
> 最后更新：2026-10-23 · P2 交付（断点续传 / 多选 / 目录传输 / 拖拽 / 预览）

---

## 0. 三分钟上手

| 项 | 内容 |
|---|---|
| 仓库 | `https://github.com/david88558855/Nimbo`（分支 `main`） |
| 产物 | Windows x64 便携 zip + Android arm64 APK |
| **硬约束** | **禁止本地编译**。本机没有 Flutter SDK，所有编译、静态检查、依赖解析只在 GitHub Actions 里发生 |
| 真相来源 | `lib/` + `pubspec.yaml` + `.github/workflows/build.yml`。`android/`、`windows/` **不入库**，每次构建由 CI 现生成 |
| 设计稿 | `design/index.html`（单文件、真实 CSS 渲染、可离线打开，v1.2） |
| 当前版本 | `pubspec.yaml` → `0.2.0+2` |

**工具链（CI 实测）**：Flutter 3.47.7 stable / Dart 3.13.5 / Java 17（temurin）/
runner `ubuntu-latest` + `windows-latest`。`pubspec.yaml` 的 SDK 约束写的是 `>=3.3.0`，
但代码里只用了保守语法（没有 records 之外的实验特性），升级 Flutter 一般不会炸。

主要依赖：`dio ^5.7`、`dartssh2 ^4.1`、`crypto ^3.0`、`xml ^6.5`、`path_provider ^2.1`、
`flutter_secure_storage ^9.2`、`file_picker ^8.1`（**8.x，API 与 13.x 不同，见第 5 节第 4 条**）。

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

# 取产物
gh run download <run-id> -n windows-x64-portable -D dist
gh run download <run-id> -n android-arm64 -D dist/android

# 推送：优先 git push；若报 CONNECT tunnel failed / HTTP2 framing（本机代理到
# github.com 不通，但 api.github.com 通），改用 API 通道：
python tools/push_via_api.py "提交说明"
```

`tools/push_via_api.py` 用 Git Data API 直接建 blob→tree→commit→ref，
不依赖 git 传输层，因此在代理故障时仍能提交，并会正常触发 Actions。

---

## 1. 当前阶段

| 阶段 | 范围 | 状态 |
|---|---|---|
| **P0 骨架** | 五个驱动能连、能列、能读写；双端外壳；云端构建跑通 | ✅ 完成 |
| **P1 传输闭环** | 上传（file_picker）、传输队列、暂停/继续/取消/重试、速度与剩余时间、SFTP 走代理、S3 分片上传、SFTP 流式 | ✅ 完成（本轮） |
| **P2 体验补齐** | 断点续传、预览、拖拽、多选批量、目录上传下载 | 🟡 基本完成（仅差托盘） |
| **P3 打磨** | 传输记录持久化、限速、S3 分片并发、错误文案统一、自动化回归 | ⬜ 未开始 |

**一句话现状**：五个协议都能真实读写，上传下载都能排队跑，代理对五个协议全部生效；
大文件中断后能接着传（下载全协议，上传 FTP/SFTP/本地）；多选、目录上传下载、拖拽、预览都已可用；
缺的是「系统托盘」「传输记录持久化」「限速」这类收尾项。

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
- 移动：底部四 Tab；文件页头部按钮按宽度收敛（窄屏只留「上传 / 新建」）
- 挂载页：卡片列表、移除确认、只读与代理状态展示
- 添加挂载弹窗：协议选择、动态字段（S3 多出 Bucket/Region/路径风格）、**独立代理区（标注「仅对本挂载生效」）**、连接测试
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

---

## 3. 文件地图

```
lib/
  main.dart                    入口：boot() 后进入 NimboShell
  app/theme.dart               设计 token（颜色/字号/圆角）+ ThemeData（单一浅色）
  core/
    models.dart                Mount / ProxyConfig / RemoteEntry / TransferTask / 枚举与扩展
    format.dart                路径拼接与规范化、字节/速度/时间格式化、文件类型→图标与配色
    store.dart                 AppPaths（便携 userdata）、Prefs（prefs.json）、SecureStore
  drivers/
    storage_driver.dart        统一接口 + DriverException + Capability
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
    files_page.dart            文件列表、详情栏、上传入口、底部传输条
    transfers_page.dart        传输任务列表
    mounts_page.dart           挂载管理
    add_mount_page.dart        添加挂载弹窗（含代理与连接测试）
    settings_page.dart         数据/传输/安全/关于
  ui/kit.dart                  按钮、协议徽标、状态点、空状态、输入框装饰
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
6. **FTP/SFTP/WebDAV 上传中断会留下远端半截文件。** 只有 S3 有 Abort 机制。
   这是 P2 要补的（先写临时名再 rename，或做 Range 续传）。
7. **FTPS 尚未实现。** `models.dart` 里 FTP 的 hint 写着「明文 / FTPS」属于文案超前，
   实际只有明文 FTP。要么实现 `AUTH TLS`，要么把文案改成「明文 FTP」。
8. **`total` 未知时进度条不会动。** FTP 无 SIZE 时 `total = 0`，界面显示「未知大小」，
   进度按 0% 显示。若要按已传字节画动效，需要给 `TransferTask` 加不确定态。
9. **S3 目录删除只删一页。** `removeEntry` 对目录只列 1000 个对象就停，超大目录会漏。
   需要补 `IsTruncated` / `ContinuationToken` 循环。
10. **`mounts_page` 没有单挂载「测试连接」。** `testMount` 目前只在添加弹窗里用。
11. **凭据在系统安全存储里，不写 prefs.json。** Windows 便携版换机器/重装系统后凭据会丢，
    需要重新输入；这是有意的（配置可备份，密码不落盘）。
12. **浏览会话与传输各用各的连接。** `AppState._driver` 只服务浏览；
    切换挂载不会中断传输，这是设计如此，别把两者合并成单例。
13. **代理只做隧道，不改 Host。** S3 的 SigV4 把 `host` 签进去了，
    反向代理改写路径或 Host 必然 `SignatureDoesNotMatch`——文档里明确不支持这种部署。
14. **进度回调是中断点。** 写新驱动时若在长循环里不调用 `onProgress`，暂停按钮对该协议无效；
    同时注意在 `finally` 里关闭 sink/handle，否则中断会泄漏。

---

## 6. 待办（按建议顺序）

| # | 事项 | 为什么 | 难度 | 主要文件 |
|---|---|---|---|---|
| 1 | **断点续传**：HTTP Range 下载、SFTP `read(offset)`、S3 分片续传 | 「网盘」最核心的体验缺口；现在暂停=从头来 | 中 | `transfer_manager.dart`、各驱动的 `downloadTo/uploadFile` |
| 2 | **上传先写临时名再 rename** | 解决第 6 条：中断不留半截文件（FTP/SFTP/WebDAV） | 低 | 三个驱动 + `StorageDriver` 加 `atomic` 能力位 |
| 3 | **多选与批量操作** | 移动端长按多选、桌面 Shift/Ctrl 多选、批量删除/下载 | 中 | `files_page.dart`、`app_state.dart` |
| 4 | **目录上传**（递归） | 上传文件夹是常见需求 | 中 | `file_picker` 的 `getDirectoryPath` + 队列展开 |
| 5 | **预览**：图片/文本/音视频 | 决定「能不能当日常网盘用」 | 高 | 新页面 + `media_kit`（需评估体积） |
| 6 | **S3 目录删除分页** | 第 9 条 | 低 | `s3_driver.dart` |
| 7 | **S3 分片并发** | 高延迟链路下提升吞吐 | 中 | `s3_driver.dart`（当前串行） |
| 8 | **传输记录持久化** | 重启后任务列表清空 | 中 | `prefs.json` 或独立 json |
| 9 | **Windows 托盘 + 拖拽上传** | 桌面端顺手度 | 中 | 需引入 `tray_manager` / `desktop_drop`（注意 CI 平台依赖） |
| 10 | **FTPS（AUTH TLS）** 或修文案 | 对齐承诺 | 低 | `ftp_driver.dart` / `models.dart` |
| 11 | **SFTP/Local 容量** | 现在显示「未知」 | 低 | `sftp_driver.space()` 可试 `statvfs` |
| 12 | **统一错误文案** | 代理不通 vs 目标不通要分开（设计稿已定义） | 低 | `DriverException` 的 kind → 文案映射表 |

---

## 7. 后续工作建议

1. **先做 1 + 2（断点续传 + 临时名 rename）**，一次把「大文件可靠性」补齐。
   验收：1 GB 文件传到 60% 暂停 → 继续后从 60% 起；中途断网重试不留半截文件。
2. **再做 3 + 4（多选与目录上传）**，把「能不能批量搬文件」这条日常路径打通。
   验收：选 20 个文件全部入队；上传一个含子目录的文件夹，远端结构一致。
3. **然后上预览（5）**，这是产品分水岭；同时评估 `media_kit` 对 Windows/Android 包体积的影响。
4. 每个阶段结束都：CI 三绿 → 下载产物 → 手工回归（见附录）→ 更新本文档的「当前阶段」表。

**给下一位 AI 的工作方式建议**：改完先在本地做括号/引用自查 → 提交 → 等 `analyze` 绿
（它比两个平台快得多，先卡这一关）→ 平台构建失败时只抓 `--log-failed` 里带 `•` 或 `What went wrong` 的行。
一次只修一类错误，别在一个提交里混多个修复，否则定位成本很高。

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
| 暂停/继续 | 传输中点暂停 | 本地半截文件被删除；继续后从头开始（当前语义） |
| 上传刷新 | 上传完成后看列表 | 新文件自动出现 |
| 切挂载 | 传输中切换挂载 | 传输继续，列表切到新挂载 |
| 断网 | 传输中断网 | 状态转「失败」并给出可读原因，不是崩溃 |

> 上表是**建议的**回归用例；本轮只验证到「双端编译通过 + `flutter analyze` 零问题」，
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

- 最近一次成功：run `39929031916`（commit `c40180a`），`analyze` 输出 `No issues found!`
- 产物：`Nimbo-windows-x64-portable.zip` 12.3 MB、`app-release.apk` 19.2 MB
- 耗时参考：analyze ≈ 1.5 min，windows ≈ 5 min，android ≈ 6 min

**排错顺序**：先看 `analyze`（最快，绝大多数类型错误在这里就能拦住），
再抓失败的平台 job 的 `--log-failed`，只查带 `•`（Dart 侧）或 `What went wrong`（Gradle 侧）的行。
