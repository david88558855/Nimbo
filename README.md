# Nimbo

多协议网盘客户端 · Windows x64 + Android arm64 · 纯 Dart 网络与存储实现。

- 协议：FTP / SFTP / S3 兼容 / WebDAV / 本地与映射盘
- **接手必读：[`docs/PROJECT-STATUS.md`](docs/PROJECT-STATUS.md)**（当前进度、已验证范围、已知坑、待办与后续建议）
- AI / 工程接手约束与常用命令：[`AGENTS.md`](AGENTS.md)
- 视觉与交互：见 `design/index.html`（设计稿 v1.2，单一浅色主题）
- 技术分析：见 `docs/s3-addressing-analysis.md`（S3 寻址模式与第三方兼容性）
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
  state/                 app_state（浏览会话）+ transfer_manager（传输队列）
design/                  设计稿（单文件 HTML）
docs/                    技术分析
```

## 当前状态（P1，已通过云端构建）

**存储与连接**

- 五类存储驱动：FTP（自实现协议，控制与数据连接都可走代理）、SFTP（dartssh2）、
  S3 兼容（自实现 SigV4，path-style / virtual-hosted 可切）、WebDAV（PROPFIND/MKCOL/MOVE）、本地与映射盘
- 按挂载一对一代理：HTTP CONNECT 与 SOCKS5；**五个协议全部经隧道**
  （HTTP 类走 `connectionFactory`，FTP 走 Socket 工厂，SFTP 走 `ProxySshSocket`）

**传输（P1 补齐）**

- 上传闭环：`file_picker` 多选 → 入队 → 目标目录自动创建（S3 除外，键即路径）
- 队列：并发数可调（1–4），**每个任务独占一条连接**，因此可以同时上传与下载、
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

- 桌面：236 导航三栏（挂载切换器、导航、挂载列表、当前挂载的代理状态）+ 文件区 + 详情栏 + 底部传输条
- 移动：底部四 Tab；文件页头部按宽度收敛按钮，避免窄屏溢出
- **文件页根目录是「全部挂载」聚合视图**：启动后先看到所有挂载卡片，点进某个挂载才进入它的目录树；
  面包屑的「全部挂载」可随时退回
- 传输页：进行中 / 已结束分组，逐任务操作，总速度汇总

**交互（P2 已补齐）**

- 多选：文件页「选择」进入多选，支持全选 / 批量下载 / 批量删除
- 上传：按钮菜单区分「上传文件」与「上传文件夹」（递归入队并保留层级）；
  桌面可直接把文件拖进文件区
- 下载：文件与文件夹都能下载，文件夹递归展开并按同名层级落盘
- 预览：图片（≤ 24 MB，可缩放）与文本 / 代码（≤ 1 MB），其余提示下载后查看

**已知限制（下一阶段）**

| 项 | 现状 |
|---|---|
| 断点续传 | 下载全协议、上传 FTP/SFTP/本地；S3 分片续传、WebDAV 上传续传未做 |
| S3 分片并发 | 分片串行上传（正确性优先），未做多片并发 |
| SFTP 容量 | 未取 `statvfs`，容量显示「未知」 |
| 托盘 / 最小化到托盘 | 未实现 |
| 传输记录持久化 | 重启后清空 |
| 限速 | 未实现 |
