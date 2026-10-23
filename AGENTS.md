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

# 失败只抓失败步骤（CI 日志带 ANSI 色）
JOB=$(gh run view <run-id> --json jobs --jq '.jobs[]|select(.name=="analyze")|.databaseId')
gh run view --job $JOB --log-failed | sed -e 's/\x1b\[[0-9;]*m//g' | grep -E "error •|warning •"
```

`analyze` 约 1.5 分钟，是唯一门禁；`android-arm64` / `windows-x64` 各约 5–6 分钟。
**一次提交只改一类问题**，否则定位成本翻倍。

## 改代码前必须知道的

- `StorageDriver` 的 `downloadTo` / `uploadFile` 签名一变，**五个驱动都要跟着改**；
  新驱动必须在长循环里调用 `onProgress`，否则该协议的暂停/续传失效。
- 续传起点一律"实测"：下载看本地文件长度，上传看远端 `sizeOf()`。
- `file_picker` 锁 8.x、`desktop_drop` 锁 0.8.x，两者互相牵制（`cross_file` 版本冲突），
  升级要同批改。
- 每个传输任务独占一条连接；浏览会话与传输队列是两套连接，别合并。

## 网络（本沙箱）

`github.com` 需要优选 IP + `mtu 1400` + `http.version=HTTP/1.1` 才能直连；
否则用 `tools/push_via_api.py` 走 API 通道。详见 `docs/PROJECT-STATUS.md` 第 0 节与第 5 节第 16/17 条。

## 提交规范

- 中文提交信息，前缀用 `feat(P2):` / `fix(ci):` / `docs:` 这类。
- 改完能力后同步更新 `README.md` 的「当前状态」与 `docs/PROJECT-STATUS.md` 的
  阶段表 / 构建记录 / 待办，让下一个接手的人不用回溯聊天记录。
