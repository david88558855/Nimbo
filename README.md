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

## 当前状态

P0 骨架：五类存储驱动 + 挂载管理 + 文件浏览 + 下载队列 + 按挂载独立代理。
预览、上传队列暂停/续传、托盘常驻等按设计稿分期实现。
