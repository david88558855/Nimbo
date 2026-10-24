# Nimbo

多协议网盘客户端 · Windows x64 + Android arm64 · 纯 Dart 网络与存储实现。

- 协议：FTP（含匿名）/ SFTP / S3 兼容 / WebDAV / 本地与映射盘
- S3 支持 path-style / virtual-hosted，Endpoint 可带子路径（`https://host/s3`，网关型部署）
- **接手必读：[`docs/PROJECT-STATUS.md`](docs/PROJECT-STATUS.md)**（当前进度、已验证范围、已知坑、待办与后续建议）
- AI / 工程接手约束与常用命令：[`AGENTS.md`](AGENTS.md)
- 视觉与交互：见 `design/index.html`（设计稿 v1.2，单一浅色主题）
- 技术分析：见 `docs/s3-addressing-analysis.md`（S3 寻址模式与第三方兼容性）
- 技术栈审查：见 `docs/tech-stack-audit.md`（客户端是否完全使用 Flutter + 风险点）
- 构建通道说明：git 推送不通时用 `python tools/push_via_api.py "说明"`（详见交接文档第 0 节）

## 构建

本仓库**不做本地编译**，所有产物由 GitHub Actions 产出：

| Job | 产物 |
|---|---|
| `analyze` | 静态检查门禁（先跑，避免白等两个平台的编译） |
| `android-arm64` | `app-release.apk` |
| `windows-x64` | `Nimbo-windows-x64-portable.zip` |

平台目录（`android/`、`windows/`）**不入库**：CI 每次用
`flutter create --platforms=... --org com.nimbo --project-name nimbo` 在临时目录生成后拷入，
保证工程只有 `lib/`、`pubspec.yaml` 与配置是权威来源。

## 目录

```
lib/
  app/theme.dart         设计 token 与 ThemeData（单一浅色主题）
  core/                  模型、格式化、配置与凭据存储
  drivers/               五个存储驱动 + 代理连接层
    storage_driver.dart  统一接口（list / read / write / move / space）
    net.dart             HTTP CONNECT / SOCKS5 连接层（Socket + HttpClient 适配）
    sftp_socket.dart     把代理隧道包装成 dartssh2 的 SSHSocket
  pages/                 桌面三栏 / 移动底部 Tab 的自适应外壳与各页面
  state/                 app_state（浏览会话 + 聚合根）+ transfer_manager（传输队列）
  platform/              仅 Windows：托盘（desktop_shell）+ 单实例（single_instance）
assets/                  托盘图标（tray.ico / tray.png）+ fonts/（Noto Sans SC 界面字体）
design/                  设计稿（单文件 HTML）
docs/                    技术分析
```

## 进度总览

| 阶段 | 内容 | 状态 |
|---|---|---|
| P0 骨架 | 五协议能连能读写、双端外壳、云端构建 | ✅ |
| P1 传输闭环 | 上传队列、暂停/继续/取消/重试、S3 分片、SFTP 流式 | ✅ |
| P2 体验补齐 | 断点续传、多选批量、目录上传下载、拖拽、预览、聚合根 | ✅ |
| P3 打磨 | 传输记录、S3 目录分页、FTP 匿名、返回键、长按多选、托盘、单实例、便携凭据、关闭到托盘 | ✅ |
| P4 可靠性 | 限速、SFTP 容量、挂载测试/编辑、WebDAV 原子上传、S3 分片续传与并发、统一错误文案、单测 | ✅ |

## 当前状态（P4 完成，云端构建三绿 + 单测）

**存储与连接**

- 五类存储驱动：FTP（自实现协议，控制与数据连接都可走代理）、SFTP（dartssh2）、
  S3 兼容（自实现 SigV4，path-style / virtual-hosted 可切）、WebDAV（PROPFIND/MKCOL/MOVE）、本地与映射盘
- 按挂载一对一代理：HTTP CONNECT 与 SOCKS5；**五个协议全部经隧道**
  （HTTP 类走 `connectionFactory`，FTP 走 Socket 工厂，SFTP 走 `ProxySshSocket`）

**传输（P1 补齐）**

- 上传闭环：`file_picker` 多选 → 入队 → 目标目录自动创建（S3 除外，键即路径）
- 多挂载：每个挂载一条常驻会话，启动后在后台全部连上，**切换挂载不再断开**其它挂载
- 队列：并发数可调（1–4，默认 3），**每个任务独占一条连接**，因此可以同时上传与下载、
  也可以跨挂载并行；FTP 不会被自身的单控制连接卡住
- 每个任务：实时速度（平滑后）、剩余时间、暂停 / 继续 / 取消 / 重试
- 暂停语义：立即中断当前读写（在进度回调处抛出）；**已写入的字节会保留**，
  继续时从断点接着传（下载五个协议都支持，上传支持 FTP / SFTP / 本地；
  WebDAV / S3 无标准追加语义，上传会整份重传）
- S3 分片上传：> 8 MB 自动 multipart，分片数控制在 900 以内；
  任一片失败或用户暂停都会 `AbortMultipartUpload` 清理，不留垃圾分片
- SFTP 流式上下行：分块读写，不再有 64 MB 内存上限
- 空文件、大文件、中文名、非法文件名字符（Windows 落盘前替换）都已处理

**界面**

- 显示名称默认按地址自动生成（本地取目录名、网络取主机名、S3 取 bucket），可随时改名；
  清空后保存会自动补回默认值
- 添加挂载：S3 / WebDAV **端口写在地址里**（`https://host:8443/dav`），表单实时解析出「端口 + 基础路径」；
  FTP / SFTP 仍用独立端口框
- 字体：Windows 端统一 Arial（系统自带，不打包）；中文由回落链 微软雅黑 → Segoe UI 提供，
  其它平台沿用 Flutter 默认字体
- 桌面文件页标题行有「返回上层」（子目录→上级，挂载根→全部挂载；聚合根置灰），移动端用系统返回键
- 桌面：236 导航三栏（挂载切换器、导航、挂载列表、当前挂载的代理状态）+ 文件区 + 详情栏 + 底部传输条
- 移动：底部四 Tab；文件页头部按宽度收敛按钮，避免窄屏溢出；
  **Android 整体字号放大 1.2 倍**（`uiSize()` 同步放大控件高度与图标，布局加固见交接文档 2.10）
- **文件页根目录是「全部挂载」聚合视图**：启动后先看到所有挂载卡片，点进某个挂载才进入它的目录树；
  面包屑的「全部挂载」可随时退回
- 传输页：进行中 / 已结束分组，逐任务操作，总速度汇总

**交互（P2 已补齐）**

- 默认隐藏以 `.` 开头的文件与目录（设置里可关闭过滤）
- 多选：文件页「选择」进入多选，或长按任意条目；支持全选 / 批量下载 / 批量删除 / 复制 / 移动
- 复制 / 移动：行内「更多」或多选条「更多操作」→ 选目标（**可跨挂载**）；同挂载移动=rename、
  同挂载复制优先服务端复制、跨挂载走本地中转
- 上传：按钮菜单区分「上传文件」与「上传文件夹」（递归入队并保留层级）；
  桌面可直接把文件拖进文件区
- 下载：文件与文件夹都能下载，文件夹递归展开并按同名层级落盘；**下载目录可配**
  （默认跟随系统：Windows 读注册表的「下载」已知文件夹、Android 公共 `Download/Nimbo`；
  目录被删或不可写时自动回落到应用私有目录）
- 预览：图片（≤ 24 MB，可缩放）与文本 / 代码（≤ 1 MB），其余提示下载后查看
- 传输记录：落盘到 `userdata/transfers.json`，重启后恢复为「已暂停」，由你决定是否继续
- 返回键：非文件页 → 文件页；子目录 → 上级；挂载根 → 全部挂载；再按一次（2 秒内）才退出应用
- Windows 托盘：左键单击无响应、双击与右键菜单「显示主窗口」共用同一入口、悬停提示「Nimbo」
  （右键依赖 `setContextMenuTrigger(rightClicked)`，`tray_manager 0.8` 的兼容层不会自动开）
- Windows 单实例：重复启动只会唤起已有窗口，不会出现第二个进程
- 便携：配置与凭据都跟随程序目录（`userdata/`），整个文件夹拷走即可带走挂载

**可靠性（P4 补齐）**

- 限速：设置页按 KB/s 配上传/下载，令牌桶在五个驱动的读写循环里生效，0 = 不限
- 断点续传：下载全协议；上传 FTP/SFTP/本地按远端实际大小续传；
  **S3 分片续传**（`uploadId` + 分片 ETag 落盘，3 路并发，续传前用 `ListParts` 核对）；
  **WebDAV 上传续传**（探测式 partial PUT：从 `*.nimbo-part` 的实测长度续写并校验总长度，
  服务器不支持时自动整份重传，不会拼出错位文件）
- 原子落盘：WebDAV 上传先写 `*.nimbo-part` 再 `MOVE`，中断不会留下半截正式文件
- 容量：SFTP 走 `statvfs`，文件页标题显示「剩余」
- 挂载管理：单挂载「测试连接」+「编辑」（密码留空不改），改完自动重连
- 错误文案：按 `DriverErrorKind` 统一给出「发生了什么 + 下一步怎么办」
- 未知总大小时进度条画不确定态，不再停在 0%

**已知限制（下一阶段）**

| 项 | 现状 |
|---|---|
| 预览 | 仅图片与文本，音视频 / PDF 未做（要评估 media_kit / pdfx 的包体积） |
| 本地磁盘容量 | `dart:io` 无 API，需 `dart:ffi` 调 `GetDiskFreeSpaceExW`，未做 |
| FTPS | 只有明文 FTP（文案已如实标注） |
| WebDAV 上传续传 | 依赖服务端支持 `PUT` + `Content-Range`；不支持的服务器自动降级为整份重传 |
| 限速粒度 | 目前是全局桶，没有「单任务限速」 |
