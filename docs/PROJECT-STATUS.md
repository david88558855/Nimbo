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
| 当前版本 | `pubspec.yaml` → `0.3.0+3` |

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
| **P3 打磨** | 传输记录持久化 ✅、S3 目录分页删除 ✅、FTP 匿名 ✅、返回键逐级回退 ✅、移动端长按多选 ✅；限速、S3 分片续传/并发、WebDAV 上传续传、临时名 rename、托盘 ⬜ | 🟡 进行中 |

**一句话现状**：五个协议都能真实读写，上传下载都能排队跑，代理对五个协议全部生效；
大文件中断后能接着传（下载全协议，上传 FTP/SFTP/本地）；多选、目录上传下载、拖拽、预览、
文件页聚合根、返回键逐级回退、传输记录持久化都已可用；
剩余的是「托盘」「限速」「S3/WebDAV 上传续传」这类需要真机联调的高风险项。

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

### 2.8 P3 打磨（进行中）

| 能力 | 实现要点 |
|---|---|
| FTP 匿名 | `Mount.anonymous` + 表单开关（开启后用户名/密码置灰）；`USER` 之后**按回复码**决定是否补 `PASS`：230 说明直接通过、331 才发密码，匿名默认 `anonymous@` |
| 返回键 | `PopScope`：非文件页 → 文件页；多选 → 退出多选；子目录 → 上级；挂载根 → 全部挂载；**只有「全部挂载」根允许退出应用** |
| S3 目录删除 | `IsTruncated` + `NextContinuationToken` 循环，不再只删前 1000 个键 |
| 长按多选 | 行内长按进入多选（移动端主入口），单项操作走行尾「更多」菜单 |
| 传输记录持久化 | `core/transfer_store.dart` → `userdata/transfers.json`，保留 60 条；启动恢复为「已暂停」，不自动重跑；状态变化 700 ms 防抖落盘，退出时再落一次 |

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
    files_page.dart            文件列表、详情栏、上传入口、多选条、拖拽接收、底部传输条
    preview_page.dart          图片/文本预览对话框（canPreviewEntry + showPreview）
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
6. **上传中断的远端残留要看协议。** S3 走 `AbortMultipartUpload` 清理；FTP/SFTP 的续传
   依赖「远端大小 == 记录偏移」，不一致就整份重传并覆盖；WebDAV 没有标准追加语义，
   中断必留半截文件，下次整份覆盖。**别假设「暂停一定续传」**，以 `driver.resume` 为准。
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

---

## 6. 待办（按建议顺序，P2/P3 已完成项已移出）

| # | 事项 | 为什么 | 难度 | 主要文件 |
|---|---|---|---|---|
| 1 | **Windows 系统托盘**（关闭/最小化到托盘、托盘菜单） | 桌面端最后一块体验缺口。`tray_manager 0.8` 是全新 native API（`TrayIcon.create()`），需要图标资源与 `window_manager` 拦截关闭事件 | 中 | `main.dart`、`shell.dart`、`pubspec.yaml`、`assets/` |
| 2 | **S3 分片续传 + 分片并发** | 中断后整份重传成本最高；并发能改善高延迟链路。需持久化 `uploadId` 与已完成分片表 | 高 | `s3_driver.dart`、`transfer_manager.dart` |
| 3 | **WebDAV 上传续传** | 标准 WebDAV 无追加语义，只能走第三方分块扩展或临时名 + rename | 高 | `webdav_driver.dart` |
| 4 | **上传先写临时名再 rename** | 解决 WebDAV/FTP 中断残留；需要 `StorageDriver` 加 `atomic` 能力位 | 中 | `storage_driver.dart` + 三个驱动 |
| 5 | **限速** | 上传/下载限速（全局或单任务） | 中 | 传输循环加令牌桶 |
| 6 | **SFTP / 本地容量** | 现在恒为「未知」；SFTP 可试 `SftpClient.statvfs`（API 未在文档站生成，需实际验证） | 低 | `sftp_driver.space()`、`local_driver.space()` |
| 7 | **统一错误文案** | 代理不通 vs 目标不通要能区分；`DriverErrorKind` 已有，缺映射表 | 低 | `ui/` 新增文案映射 + 各 `catch` |
| 8 | **预览扩展（音视频 / PDF）** | 现在只覆盖图片与文本；`media_kit` 需评估包体积 | 高 | `preview_page.dart` |
| 9 | **FTPS（AUTH TLS）** | 目前只有明文 FTP，文案已改为「明文 FTP」；实现需要 TLS 升级 | 中 | `ftp_driver.dart` |

---

## 7. 后续工作建议

1. **先做托盘（1）**：它是「看起来完成」的最后一块，且改动局限在桌面外壳，回归面小。
   注意 `tray_manager 0.8` 与 0.5.x 的 API 完全不同（新 API 是 `TrayIcon.create()`，
   旧写法要 `import 'package:tray_manager/legacy.dart'`），网上多数示例是旧 API。
2. **再做 4 + 2（临时名 rename → S3 分片续传）**，把「大文件可靠性」补到底。
   验收：1 GB 传 60% 暂停 → 继续从 60% 起；中途杀进程重启后仍能续（需 6 先做）。
3. **然后 6 + 7（持久化 + 限速）**，这两项都属于「设置里有开关、行为可预期」的产品化收尾。
4. 每个阶段结束都：CI 三绿 → 下载产物 → 按附录回归 → 更新本文档的「当前阶段」表与「构建记录」。

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

- 最近一次成功：run `39970353975`（commit `0237274`），`analyze` 输出 `No issues found!`
- 产物：`windows-x64-portable.zip` 12.53 MB（内含 `Nimbo.exe`）、`app-release.apk` 20.5 MB（arm64 release）
- 耗时参考：analyze ≈ 1.5 min，windows ≈ 5 min，android ≈ 6 min

**排错顺序**：先看 `analyze`（最快，绝大多数类型错误在这里就能拦住），
再抓失败的平台 job 的 `--log-failed`，只查带 `•`（Dart 侧）或 `What went wrong`（Gradle 侧）的行。
