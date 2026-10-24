# Nimbo 代码审查与缺陷清单（交接用）

> 审查时间：2026-10-24（commit `eac8884` 之后）
> 范围：`lib/` 全量（状态层 / 传输层 / 五个驱动 / 平台层 / 主要页面），不含 `design/`、`tools/`
> 方式：静态阅读 + 对照已踩过的坑（`PROJECT-STATUS.md` 第 5 节）。**尚未在真机跑过**，
> 下面每条都标了复现条件，修复后请按「验收标准」逐条确认。
> 结论：**未发现会让程序立刻不可用的缺陷**；但有 4 条会造成「配置丢失 / 状态错乱」。
> **进展：Batch A（BUG-01/02）与 Batch B（BUG-03/04/10/11/14）已修**（2026-10-24），
> 剩余 Batch C/D/E 待处理（见文末进度勾选）。

---

## 1. P0/P1 — 会丢数据或明显出错

### BUG-01 `Prefs.save()` 并发写坏配置文件（P0）

- **位置**：`lib/core/store.dart:158`
- **成因**：`save()` 没有串行化。`AppState.open()`、`updateSettings()`、`flush()`（托盘退出时）
  都可能在任意时刻调用它；两次 save 会同时写同一个 `prefs.json.tmp` 再 rename，
  交错写入的临时文件被 rename 成正式文件 → JSON 截断/串内容。
- **影响**：下一次启动解析失败，走 `catch` 按空配置启动 → **用户所有挂载消失**。
- **复现**：连续快速改两次设置（限速输入框失焦会触发保存），同时点开一个挂载。
- **修复建议**：内部用一条 Future 链串行化（`_writing = _writing.then((_) => _doSave())`），
  或每次写 `prefs.json.<pid>.<seq>.tmp` 再 rename（rename 本身在 Windows 上是原子的）。
- **验收**：并发触发 20 次 `save()` 后，`prefs.json` 仍是合法 JSON 且挂载数不变。

### BUG-02 `Prefs.load()` 单条解析失败会丢掉后续全部挂载（P0）

- **位置**：`lib/core/store.dart:144-149`
- **成因**：`mounts..clear()..addAll(list.whereType<Map>().map(Mount.fromJson).where(...))`
  是惰性链，`addAll` 边迭代边写入；任一条目抛错（如 `id` 缺失时 `j['id'] as String` 强转）
  会中断 addAll 并跳到外层 catch。此时 `mounts` 已被 clear、只装了前几条。
- **影响**：**只要有一次保存动作，剩余的挂载就被永久删除**（配置里已经没了）。
- **复现**：手工把 `prefs.json` 里某个 mount 的 `id` 删掉再启动，然后改一次设置。
- **修复建议**：逐条 `try { mounts.add(Mount.fromJson(e)); } catch (_) {}`；
  解析前把原文件复制成 `prefs.json.bak-<时间戳>`；`Mount.fromJson` 里 `id` 用 `as String?` + 兜底。
- **验收**：坏条目被跳过，其余挂载完整；`prefs.json.bak-*` 存在。

### BUG-03 `sessionFor()` 缺 in-flight 去重，会漏连接（P1）

- **位置**：`lib/state/app_state.dart:106`
- **成因**：先查 `_sessions[mount.id]`，再 `await createDriver(...)+connect()`，最后才写回 Map。
  这段窗口里（S3/WebDAV 握手 100 ms～2 s）任何二次调用（启动 `warmUp()` 与用户点击、
  或复制对话框里选同一个挂载）都会各建一条连接，后写覆盖前者，先建的那条**没人 close**。
- **影响**：连接泄漏；FTP/SFTP 会占着对端会话，服务端可能有连接数上限，久了报「too many connections」。
- **修复建议**：加 `Map<String, Future<StorageDriver>> _pending`，`sessionFor` 优先复用未完成的 Future；
  `finally` 里清 `_pending`。
- **验收**：启动瞬间连点同一挂载 5 次，抓包/日志只出现一次 connect。

### BUG-04 `cancel()` 先删文件后 abort，半截文件会被写回（P1）

- **位置**：`lib/state/transfer_manager.dart:279`（配合 `_run` 的 finally）
- **成因**：`cancel()` 同步 `_discardPartial()` 删本地文件，此时 `_run` 里的下载循环仍持有
  `RandomAccessFile`；abort 要等下一次 `onProgress` 才抛。Windows 上删除打开中的文件会失败
  （被 `try/catch(_)` 吞掉），随后驱动继续写 → 文件回来了。
- **影响**：用户点「取消」后仍留半截文件（且任务已从列表移除，用户没法再删）。
- **修复建议**：`cancel` 只置 `abort + remove`，删除动作挪到 `_run` 的 finally（或 `close()` 之后）
  统一执行：`if (task.abort && task.dir == download) _discardPartial(...)`。
- **验收**：下载 50% 时点取消，磁盘上无残留文件、无 `.part`。

---

## 2. P2 — 健壮性 / 性能

| ID | 位置 | 成因 | 影响 | 修复建议 |
|---|---|---|---|---|
| BUG-05 | `core/limiter.dart:55` | `take()` 只在入口判断 `_rate<=0`；循环中把限速改成 0 后，`need*1000/_rate` = `Infinity`，`.ceil()` 抛 `UnsupportedError` | 传输直接失败（错误文案看不出是限速导致） | 循环每轮重查 `_rate<=0` 直接 `return` |
| BUG-06 | `state/app_state.dart:532` | 只拦了「目录复制进自己」，未拦「目标目录 == 源所在目录」 | 本地 `File.copy` 拷到自身抛 `FileSystemException`；WebDAV `COPY` 到自身可能 403 或覆盖原文件 | `dest == e.path` 时跳过该条目并提示「目标与源相同」 |
| BUG-07 | `state/transfer_manager.dart:555` | `downloadDir()` 每次都 `Process.run('reg', ...)`；批量下载 N 个文件 = N 次进程创建 | 100 个小文件下载时明显变慢（每次几十 ms） | 进程内缓存注册表读取结果（`static String? _cached`） |
| BUG-08 | `state/app_state.dart:33` | `_onTransfers()` 用「done 计数变化」触发 `refresh()`，目录批量传输时每完成一个文件刷一次 | N 次多余的 `list` 请求，弱网下界面一直转圈 | 节流合并（1~2 s），或仅当「完成项父目录 == 当前 path」时刷新 |
| BUG-09 | `drivers/ftp_driver.dart`（`retr`/`stor` 数据连接）、`drivers/sftp_driver.dart` | 数据读写无空闲超时；abort 只在收到数据时检查 | 服务器半死时传输**永久卡住**，点暂停/取消都无反应，只能关程序 | FTP 数据 socket 加 `.timeout()`；SFTP 用 `Future.timeout` 包每次读块；超时抛 `DriverErrorKind.network` |
| BUG-10 | `state/app_state.dart:207` | 连接失败先写 `_sessionErrors[id]`，紧接着 `dropSession(id)` 又把同一个键删掉 | `mountError()` 永远返回 null，界面拿不到「为什么连不上」 | `dropSession` 增加 `keepError` 参数（或改为 `_closeSession` 不清错误） |
| BUG-11 | `platform/single_instance.dart:78` | 第一实例 accept 后没有读超时；外部程序连上却不发数据 | socket 永久挂着，每次启动多一个，长期运行会累积 | accept 后启动 5 s 计时器，超时 `socket.destroy()` |
| BUG-12 | `state/app_state.dart`（`warmUp()` / `_warmOne()` 与 `removeMount()`） | 预热与删除挂载竞态：删除时预热正在连它，连完仍写回 `_sessions` | 已删挂载留下一条无主连接；后续 `dropSession` 也不会再被调用 | `_warmOne` 成功后校验 `_prefs.mounts` 里是否还有该 id，没有就立即 `dropSession` |

---

## 3. P3 — 体验与清理

| ID | 位置 | 问题 | 建议 |
|---|---|---|---|
| BUG-13 | `drivers/local_driver.dart:55` | `existsSync` / `listSync` 同步 IO，大目录（上万项）会卡住 UI 线程 | 改 `await dir.exists()` / `await for (final e in dir.list())` |
| BUG-14 | `state/transfer_manager.dart:410` | 不支持续传时立刻删半截文件，但驱动仍握句柄（finally 才 close）→ 删除静默失败、文件残留 | 删除动作挪到 `driver.close()` 之后（与 BUG-04 一起改最省事） |
| BUG-15 | `drivers/webdav_driver.dart` | 上传中断残留 `*.nimbo-part`，异常退出后无自动清理 | 同名上传前先 `sizeOf(temp)` 并复用/覆盖；设置页给「清理残留」按钮 |
| BUG-16 | `state/app_state.dart`（`deletePicked`） | 串行删除、无 busy 态，大目录时按钮仍可点 | 加 `deleting` 标志，按钮置灰 + 显示「已删 n/total」 |

---

## 4. 修复批次计划（建议按此推进，每批单独 push + 等 CI）

| 批次 | 内容 | 为什么这一批 | 预计改动面 |
|---|---|---|---|
| **Batch A（数据安全）** ✅ 已完成 | BUG-01、BUG-02（+ `Mount.fromJson` 的 `id` 兜底） | 唯一会「用几天后挂载全没」的路径；已补 `parseMounts` 单测 5 例（并发 save 无法在纯单测里模拟，靠串行化实现保证） | `core/store.dart`、`core/models.dart`、`test/core_logic_test.dart` |
| **Batch B（会话与取消）** ✅ 已完成 | BUG-03、BUG-04、BUG-10、BUG-11、BUG-14 | 都是「点了没反应 / 状态不对」的用户可感知问题 | `app_state.dart`、`transfer_manager.dart`、`models.dart`、`single_instance.dart` |
| **Batch C（正确性与性能）** | BUG-05、BUG-06、BUG-07、BUG-08 | 纯局部修复，风险低；BUG-05/06 有明确复现步骤，容易写用例 | `limiter.dart`、`app_state.dart`、`transfer_manager.dart` |
| **Batch D（加固）** | BUG-09、BUG-12 | BUG-09 涉及驱动读写循环，改完必须真机跑一次大文件暂停/取消 | `ftp_driver.dart`、`sftp_driver.dart`、`app_state.dart` |
| **Batch E（打磨）** | BUG-13、BUG-15、BUG-16 | 体验项，可随时插入 | `local_driver.dart`、`webdav_driver.dart`、`app_state.dart` |

**进度勾选**（修完把 `[ ]` 改成 `[x]` 并写上 commit）：

- [x] BUG-01 配置并发写（P0）—— `Prefs.save()` 改为 Future 链串行 + 每次唯一 `.tmp` 名
- [x] BUG-02 挂载解析失败丢配置（P0）—— 抽出 `parseMounts()` 逐条容错，坏条目跳过并备份 `prefs.json.bak-*`；
      `Mount.fromJson` 的 `id` 改 `as String?` 兜底
- [x] BUG-03 sessionFor 去重（P1）—— 新增 `_pending` 复用同一条 in-flight Future
- [x] BUG-04 取消后残留半截文件（P1）—— 改标记 + 驱动关闭后再删
- [ ] BUG-05 运行中改限速除零（P2）
- [ ] BUG-06 复制到源目录（P2）
- [ ] BUG-07 注册表每次下载都查（P2）
- [ ] BUG-08 完成一个就刷新（P2）
- [ ] BUG-09 FTP/SFTP 无读超时（P2）
- [x] BUG-10 连接错误被清掉（P2）—— `open()` 失败路径改为先 dropSession 再写错误
- [x] BUG-11 单实例 socket 无超时（P2）—— accept 后 5 秒 guard
- [ ] BUG-12 预热与删除竞态（P2）
- [ ] BUG-13 本地列表同步 IO（P3）
- [x] BUG-14 半截文件删除时机（P3）—— 与 BUG-04 同一次改动
- [ ] BUG-15 WebDAV 临时文件清理（P3）
- [ ] BUG-16 批量删除无 busy 态（P3）

---

## 5. 给接手者的操作提示

1. **禁止本地编译**（本机没有 Flutter SDK）。所有验证走 CI：push `main` 自动触发
   `analyze + flutter test + android-arm64 + windows-x64`（约 8~9 分钟）。
2. 查构建：

   ```bash
   env -u HTTPS_PROXY -u HTTP_PROXY -u ALL_PROXY gh run list --limit 3
   env -u HTTPS_PROXY -u HTTP_PROXY -u ALL_PROXY gh run view <id> --json jobs \
     --jq '.jobs[]|"\(.name) => \(.status)/\(.conclusion)"'
   ```

3. 取失败日志（CI 日志带 ANSI 色）：

   ```bash
   env -u HTTPS_PROXY -u HTTP_PROXY -u ALL_PROXY gh run view --job <jobId> --log-failed \
     | sed -e 's/\x1b\[[0-9;]*m//g' | tail -40
   ```

4. 推送：**本地代理 `127.0.0.1:10808` 可能不可用**（2026-10-24 起 curl 返回 000）。
   若 `TLS connect error: unexpected eof`，改用直连：

   ```bash
   git -c http.proxy= -c https.proxy= push origin main
   ```

5. 每批修完在 `docs/PROJECT-STATUS.md` 第 9 节补一行构建记录，并勾选本文档的清单。
6. 改动 `prefs.json` / `transfers.json` 结构时**必须**同时更新 `PROJECT-STATUS.md` 第 5 节的坑列表。
