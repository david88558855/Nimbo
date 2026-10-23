# Nimbo

多协议网盘客户端 · Windows x64 + Android arm64 · 纯 Dart 网络与存储实现。

- 协议：FTP / SFTP / S3 兼容 / WebDAV / 本地与映射盘
- 视觉与交互：见 `design/index.html`（设计稿 v1.2，单一浅色主题）
- 技术分析：见 `docs/s3-addressing-analysis.md`（S3 寻址模式与第三方兼容性）

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
  pages/                 桌面三栏 / 移动底部 Tab 的自适应外壳与各页面
  state/                 Riverpod 控制器（挂载、文件、传输）
design/                  设计稿（单文件 HTML）
docs/                    技术分析
```

## 当前状态（P0，已通过云端构建）

已完成并编译通过：

- 五类存储驱动：FTP（自实现协议，控制/数据连接均可走代理）、SFTP（dartssh2）、
  S3 兼容（自实现 SigV4，path-style / virtual-hosted 可切）、WebDAV（PROPFIND/MKCOL/MOVE）、本地与映射盘
- 按挂载一对一代理：HTTP CONNECT 与 SOCKS5，`connectionFactory` 直接接管 HTTP 栈
- 挂载管理：协议表单、连接测试、只读、凭据进系统安全存储
- 文件浏览：面包屑、列表、详情栏、新建文件夹、重命名、删除、下载
- 传输：下载队列与进度；Windows 便携 `userdata/prefs.json`

已知限制（下一阶段）：

| 项 | 现状 |
|---|---|
| 上传 | 驱动已实现 `uploadFile`，UI 尚未接入文件选择器 |
| SFTP 经代理 | 需自定义 `SSHSocket` 复用隧道，当前请直连 |
| S3 大文件 | >128 MB 走内存上传，分片上传未接 |
| SFTP 大文件 | >64 MB 受限（未做流式） |
| 预览 / 托盘 / 拖拽 | 未实现 |
