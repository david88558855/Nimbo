# Nimbo 进度总结与交接文档

> 用途：给下一位接手的工程师 / AI 一份「一次读完就能继续开发」的现状快照。
> 深度内容不在这里重复，统一指向既有文档：
> - `docs/PROJECT-STATUS.md` —— 逐阶段交付明细、关键决策（ADR-1~28）、已知坑 1~60、回归清单、构建记录
> - `docs/bug-audit.md` —— 16 条已审查缺陷（P0–P3）、批次计划、验收标准、进度勾选
> - `docs/s3-addressing-analysis.md` —— S3 寻址模式与第三方兼容性
> - `docs/tech-stack-audit.md` —— 技术栈审查（是否纯 Flutter）
>
> 快照时间：2026-10-24 · 最新提交 `70ecf38` · CI 全绿（analyze + 46 项单测 + windows-x64 + android-arm64）

---

## 1. 项目背景与目标

| 项 | 内容 |
|---|---|
| 项目 | **Nimbo** —— 多协议云存储 / 网盘客户端 |
| 仓库 | `https://github.com/david88558855/Nimbo`（默认分支 `main`，只从 `main` 出发开发） |
| 目标平台 | **Windows 桌面**（主）+ **Android**（次）；不面向 Web |
| 解决什么问题 | 用一个客户端同时管理 FTP / SFTP / S3 兼容存储 / WebDAV / 本地与映射盘，统一的上传下载队列、断点续传、限速、多选批量、复制移动 |
| 当前版本 | `pubspec.yaml` → `0.4.0+4`；界面版本号取自 `lib/core/version.dart` 的 `kAppVersion` |
| 代码规模 | `lib/` 36 个 Dart 文件 / 约 10.3k 行；`test/` 1 个文件 / 46 个用例 |
| 硬约束 | **禁止本地编译**（本机无 Flutter SDK）。一切编译、静态检查、依赖解析只在 GitHub Actions 完成 |

**设计原则（写进 ADR 的）**：单一浅色主题不搞第二套配色；五个协议共用 `StorageDriver` 抽象，
新协议只实现一个类；传输层与浏览层解耦；能用服务端语义就不绕本地（WebDAV `COPY`/`MOVE`、S3 分片）。

---

## 2. 已完成功能模块

### 2.1 阶段总览

| 阶段 | 范围 | 状态 |
|---|---|---|
| P0 骨架 | 五驱动连通/列举/读写、双端外壳、云端构建 | ✅ |
| P1 传输闭环 | 上传入口、传输队列、暂停/继续/取消/重试、速度、SFTP 代理、S3 分片上传 | ✅ |
| P2 体验补齐 | 断点续传、预览（图片/文本）、拖拽、多选批量、目录上传下载 | ✅ |
| P3 打磨 | 传输记录持久化、S3 目录分页删除、FTP 匿名、返回键、长按多选、托盘/单实例、便携凭据、关闭到托盘 | ✅ |
| P4 可靠性 | 限速、SFTP 容量、挂载测试与编辑、WebDAV 原子上传、S3 分片续传 + 并发、统一错误文案、纯逻辑单测 | ✅ |
| P5 缺陷修复 | 全库审查 16 条；**Batch A/B 已完成（7 条）**，余 Batch C/D/E（9 条） | 🟡 进行中 |

### 2.2 功能清单（按用户可感知的能力）

**文件浏览**
- 全部挂载聚合根 + 进入挂载的目录树；面包屑可点；桌面端标题行「返回上层」按钮（移动端用系统返回键）
- 隐藏以 `.` 开头的文件（默认开启，设置里可关）；桌面列表带「大小 / 修改时间」，移动端隐藏时间列
- SFTP 容量（`statvfs`）、WebDAV quota，文件页标题显示「剩余」
- 预览：图片（≤24 MB，可缩放）与文本/代码（≤1 MB）

**传输**
- 上传 / 下载 / 目录上传下载；队列并发可调（1–4，默认 3），每任务独占一条连接
- 断点续传：下载全协议；上传 FTP/SFTP/本地按远端大小、S3 按分片表、WebDAV 探测式 partial PUT
- 暂停/继续/取消/重试；速度与总速度；传输记录落盘 `userdata/transfers.json`，重启恢复为「已暂停」
- 限速：全局令牌桶，上传/下载分开，设置页按 KB/s 配，0 = 不限

**文件操作**
- 新建文件夹、重命名、删除（单/批量）、**复制 / 移动**（同挂载走服务端或 rename，跨挂载走本地中转，可选任意挂载作为目标）

**挂载管理**
- 五种协议添加/编辑/测试连接；密码存系统凭据库（Windows 额外写便携 `credentials.dat`）
- S3/WebDAV 端口写在地址里（无独立端口框），地址解析收敛到 `core/endpoint.dart`
- **多挂载常驻连接**：启动后后台并发连接所有挂载，切换不再断开其它挂载

**平台相关**
- Windows：系统托盘（单击无响应、双击与菜单项共用 `showWindow()`、右键菜单、关闭到托盘可配）、单实例（端口区间 + 握手）、跟随系统「下载」目录、界面字体 Arial（中文回落雅黑）
- Android：底部四 Tab、长按多选、1.2 倍字号放大（`uiSize()` 同步放大控件）、公共 Download 目录

---

## 3. 代码架构与关键实现

### 3.1 目录结构

```
lib/
  main.dart                 入口：单实例 → boot() → NimboApp；Windows 首帧后初始化托盘
  app/theme.dart            设计 token + ThemeData；Arial/回落链、uiSize()、nimboTextScaler()
  core/
    models.dart             Mount / RemoteEntry / ProxyConfig / TransferTask / AppSettings
    store.dart               AppPaths、Prefs（**串行化保存 + parseMounts 容错**）、SecureStore
    format.dart              路径工具（join/parent/normalize）、字节与日期格式化、sanitizeName
    endpoint.dart            S3/WebDAV 地址解析（协议/主机/端口/基础路径）
    version.dart             版本号单一来源
    limiter.dart             令牌桶限速（上传/下载各一桶）+ throttleStream
    transfer_store.dart      传输记录持久化（transfers.json，保留 60 条）
    multipart_store.dart     S3 分片上传状态（multipart.json：uploadId + 分片 ETag）
    upload_checkpoint.dart   WebDAV 上传断点（uploads.json：大小 + mtime + offset）
    json_store.dart          小 JSON 状态文件的串行化读-改-写 + 原子落盘
  drivers/
    storage_driver.dart      统一接口 + Capability + ResumeSupport + uploadResumeOffset/copyEntry 默认实现
    factory.dart             createDriver / testMount / testMountWithStoredPassword
    net.dart                 带代理的 Socket 包装（SFTP 走代理的关键）
    sftp_socket.dart         dartssh2 的 SSHOverSSH socket 适配
    local/ftp/sftp/s3/webdav_driver.dart
    s3_path.dart             S3 请求路径拼装（含 Endpoint 子路径）+ uriEncodeS3
    errors.dart              describeError / shortError（按 DriverErrorKind 给可执行建议）
  state/
    app_state.dart           浏览会话、**多挂载会话表**、复制/移动编排、设置、容量
    transfer_manager.dart    传输队列、并发控制、续传起点、速度采样、落盘
  pages/
    shell.dart               桌面侧栏 / 移动底部 Tab / 返回键
    files_page.dart          文件列表、详情栏、多选条、拖拽、上传入口、复制移动入口
    mounts_page.dart         挂载管理卡片
    add_mount_page.dart      添加/编辑挂载弹窗（名称必填、端口归入地址、解析预览）
    pick_destination.dart    复制/移动目标选择器（可跨挂载）
    settings_page.dart       设置（外观/传输/桌面）
    transfers_page.dart      传输列表与分组
    preview_page.dart        图片/文本预览
  platform/
    desktop_shell.dart       托盘、菜单、窗口显隐、关窗行为、退出前落盘
    single_instance.dart     单实例（端口区间 + 握手 + 5s 读超时）
  ui/kit.dart                NimboButton/ProtocolBadge/StatusDot/EmptyBlock/输入框装饰
test/core_logic_test.dart    纯逻辑单测 46 项
```

### 3.2 关键实现要点

| 主题 | 实现位置与做法 |
|---|---|
| 驱动抽象 | `StorageDriver` 定义 `connect/close/list/downloadTo/uploadFile/mkdir/removeEntry/move/copyEntry/space`；`copyEntry` 默认「下载到临时文件→上传」，本地与 WebDAV 覆写为服务端语义 |
| 多挂载会话 | `AppState._sessions: Map<String, StorageDriver>` + `_pending`（in-flight 去重）。`sessionFor()` 取或建、`dropSession()` 关并清、`warmUp()` 启动后台全连；`_driver` 只是按当前挂载查表 |
| 传输队列 | `TransferManager._pump()` 同步调度（Dart 单线程保证原子），每任务**独立建连/断连**；abort 通过进度回调抛 `TransferAborted` 实现；`discardPartial` 标记保证删除发生在驱动关闭后 |
| 续传 | 下载起点以本地文件真实长度为准；上传由驱动 `uploadResumeOffset()` 复核远端大小；S3 分片表 + `ListParts` 以服务端为准；WebDAV 用 `Content-Range` 并**以总长度自校验**判定服务器是否支持 |
| 限速 | 全局 `TransferLimiter` 两个令牌桶；驱动在自己读写循环里 `await take(n)`；整条 Stream 交给 dio 的场景用 `throttleStream()` |
| 配置持久化 | `Prefs.save()` **Future 链串行** + 唯一临时名 + 原子 rename；`parseMounts()` 逐条容错，坏配置自动备份 `prefs.json.bak-*` |
| 凭据 | `SecureStore`：系统凭据库优先，Windows 失败回落便携文件（固定密钥 XOR + base64，可逆混淆） |
| 单实例 | 47913–47922 端口区间，第二实例发 `nimbo:show`、第一实例回 `nimbo` 才认领；认领失败也不阻塞启动 |
| 托盘右键 | nativeapi 的 `ContextMenuTrigger` 默认 `None`，必须显式 `setContextMenuTrigger(rightClicked)`，否则「挂着菜单但不显示」 |
| 复制/移动 | `AppState.copyOrMoveEntries()`：同挂载移动=rename、同挂载复制=递归 `copyEntry`、跨挂载=逐文件中转；拦截「目录搬进自己」 |

### 3.3 数据文件（`userdata/`，随程序目录）

`prefs.json`（挂载 + 设置）、`transfers.json`（传输记录）、`multipart.json`（S3 分片）、
`uploads.json`（WebDAV 断点）、`credentials.dat`（Windows 便携凭据）。

---

## 4. 待解决问题与待办事项

### 4.1 缺陷清单（详见 `docs/bug-audit.md`，含复现与验收）

| 批次 | 内容 | 状态 |
|---|---|---|
| A | BUG-01 配置并发写、BUG-02 解析失败丢挂载 | ✅ 已完成（`6552b42`） |
| B | BUG-03 会话去重、BUG-04 取消残留、BUG-10 错误被清、BUG-11 socket 超时、BUG-14 删除时机 | ✅ 已完成（`53c8a86`） |
| C | BUG-05 限速改 0 除零、BUG-06 复制到源目录、BUG-07 注册表每次查询、BUG-08 完成即刷新 | ⬜ 待做 |
| D | BUG-09 FTP/SFTP 无读超时（卡死不可取消）、BUG-12 预热与删除竞态 | ⬜ 待做 |
| E | BUG-13 本地列表同步 IO、BUG-15 WebDAV 临时文件清理、BUG-16 批量删除无 busy 态 | ⬜ 待做 |

### 4.2 功能待办（按建议顺序）

| # | 事项 | 难度 | 主要文件 |
|---|---|---|---|
| 1 | 预览扩展（音视频 / PDF）：需评估 `media_kit` / `pdfx` 的包体积与 native 依赖 | 高 | `preview_page.dart`、`pubspec.yaml` |
| 2 | 本地磁盘容量：`dart:ffi` 调 `GetDiskFreeSpaceExW`，注意错误兜底 | 中 | 新增 `platform/disk_space.dart` |
| 3 | FTPS（`AUTH TLS` + `PROT P`，控制与数据连接各升一次） | 中 | `ftp_driver.dart` |
| 4 | 任务级限速（每任务一个桶，需持久化到 `TransferTask`） | 中 | `limiter.dart`、`transfer_manager.dart` |
| 5 | S3 分片状态可视化清理（`ListMultipartUploads` + 设置页入口） | 低 | `multipart_store.dart`、`settings_page.dart` |
| 6 | 真机回归：第 8 节那张手工回归清单尚未完整跑过（P0–P5 只验证到编译 + 单测） | — | — |

### 4.3 已知限制（设计取舍，非缺陷）

- 未做统一 VFS：跨挂载仍不能「一个根目录浏览/拖拽」，多挂载只做到「连接常驻」
- WebDAV 上传续传依赖服务端支持 partial PUT，不支持时自动整份重传
- 限速是全局桶，没有单任务限速
- Android 11+ 未申请「所有文件访问」，公共 Download 写不进去时回落到应用私有目录

---

## 5. 下一步开发计划

1. **Batch C（4 条，低风险，单文件内）**：BUG-05 → BUG-06 → BUG-07 → BUG-08。每条独立可测，
   建议一次推送统一跑 CI。
2. **Batch D（2 条，需真机）**：BUG-09 给 FTP 数据连接与 SFTP 读块加超时；BUG-12 预热完成校验挂载仍存在。
   **改完必须真机验证「大文件暂停/取消」**，这是本轮唯一影响传输主路径的改动。
3. **Batch E（3 条打磨）**：本地列表异步化、WebDAV 临时文件清理、批量删除 busy 态。
4. **功能项 1（预览扩展）**：用户感知最强；先量 `media_kit` 体积再决定是否只做「音频 + PDF」。
5. **功能项 2/3（本地容量 / FTPS）**：协议能力补齐，互不依赖。
6. **真机回归**：按 `docs/PROJECT-STATUS.md` 第 8 节清单在 Windows + Android 各跑一遍，
   通过后把清单里的「未验证」标记清掉。

每批结束的固定动作：CI 三绿 → 下载产物 → 按需真机验证 → 更新 `PROJECT-STATUS.md` 构建记录与
`bug-audit.md` 进度勾选 → 更新本快照的「阶段总览」。

---

## 6. 依赖与环境配置

### 6.1 运行时依赖（`pubspec.yaml`）

| 包 | 版本 | 用途 / 注意 |
|---|---|---|
| `dio` | ^5.7 | HTTP（S3 / WebDAV），带连接/接收/发送超时 |
| `dartssh2` | ^4.1 | SFTP 客户端 |
| `xml` | ^6.5 | S3 响应与 WebDAV PROPFIND 解析 |
| `crypto` | ^3.0 | S3 SigV4 签名 |
| `path` / `path_provider` | ^1.9 / ^2.1 | 路径与数据目录 |
| `flutter_secure_storage` | ^9.2 | 系统凭据库 |
| `file_picker` | ^8.1 | **锁 8.x**（API 与 13.x 不同），选文件/目录 |
| `desktop_drop` | ^0.8.4 | **锁 0.8.x**（0.9.x 与 file_picker 8 的 `cross_file` 冲突） |
| `tray_manager` | ^0.8.0 | 托盘（nativeapi 后端，注意 `ContextMenuTrigger` 默认 `None`） |
| `window_manager` | ^0.5.2 | 窗口尺寸/关闭拦截 |

dev：`flutter_test`、`flutter_lints ^4.0`。

### 6.2 工具链与 CI（`.github/workflows/build.yml`）

- 触发：push `main` / `v*` tag / PR / 手动 dispatch
- Job：`analyze`（`flutter analyze --no-fatal-infos --no-fatal-warnings` + `flutter test`，
  Linux 上先 `apt install libgtk-3-dev libx11-dev libxi-dev`，因为 nativeapi 的 native assets 需要）
  → `android-arm64` → `windows-x64`
- `android/`、`windows/` **不入库**，由 CI `flutter create --platforms=...` 现生成；
  网络权限、明文流量、外部存储权限、`compileSdk 36` 都由 workflow 的 sed 注入
- 产物：`windows-x64-portable.zip`（约 12.5 MB，须整包带 DLL）、`app-release.apk`（约 20.5 MB，arm64）
- 实测版本：Flutter 3.47.7 / Dart 3.13.5 / Java 17（temurin），runner `ubuntu-latest` + `windows-latest`
- 耗时参考：analyze ≈ 1.5 min，windows ≈ 5 min，android ≈ 6 min

### 6.3 本地环境注意

- 本机 **没有 Flutter SDK**，不能 `flutter run` / `flutter build`；验证只能靠 CI
- 网络：本地代理 `127.0.0.1:10808` 与直连都可能短时不可用。推送/查询任选其一，失败就换另一个：
  ```bash
  # 推送（二选一）
  git -c http.proxy=http://127.0.0.1:10808 -c https.proxy=http://127.0.0.1:10808 push origin main
  git -c http.proxy= -c https.proxy= push origin main

  # 查构建（gh 会读环境变量里的代理，直连时清掉）
  env -u HTTPS_PROXY -u HTTP_PROXY -u ALL_PROXY gh run list --limit 3
  ```

---

## 7. 常用操作速查

```bash
# 看构建
env -u HTTPS_PROXY -u HTTP_PROXY -u ALL_PROXY gh run list --limit 3
env -u HTTPS_PROXY -u HTTP_PROXY -u ALL_PROXY gh run view <id> --json jobs \
  --jq '.jobs[]|"\(.name) => \(.status)/\(.conclusion)"'

# 取失败日志（CI 日志带 ANSI 色）
env -u HTTPS_PROXY -u HTTP_PROXY -u ALL_PROXY gh run view --job <jobId> --log-failed \
  | sed -e 's/\x1b\[[0-9;]*m//g' | tail -40

# 下载产物
env -u HTTPS_PROXY -u HTTP_PROXY -u ALL_PROXY gh run download <id> -n windows-x64-portable
```

**改代码的固定纪律**：改公共接口（`StorageDriver`、`TransferTask` JSON、`prefs.json` 结构）必须
同步更新五个驱动 + 单测 + `PROJECT-STATUS.md` 第 5 节坑列表；新增文本样式不要手写 `fontFamily`
（Windows 走主题的 Arial）；新增固定尺寸必须 `uiSize()` 且不能加 `const`。

---

## 8. 相关文档索引

| 文档 | 内容 |
|---|---|
| `docs/PROJECT-STATUS.md` | 主交接文档：三分钟上手、逐阶段明细、ADR-1~28、坑 1~60、回归清单、构建记录 |
| `docs/bug-audit.md` | 16 条缺陷（位置/成因/影响/复现/修复建议/验收）+ 批次计划 + 进度勾选 |
| `docs/s3-addressing-analysis.md` | S3 寻址模式、第三方兼容性、Endpoint 子路径 |
| `docs/tech-stack-audit.md` | 客户端是否纯 Flutter 的审查结论与风险点 |
| `AGENTS.md` | 接手第一件事 + 改代码前必须知道的约束 |
| `design/index.html` | 设计稿（单文件，可离线打开） |
