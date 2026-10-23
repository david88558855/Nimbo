import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../core/format.dart';
import '../core/models.dart';
import '../state/app_state.dart';
import '../ui/kit.dart';

class FilesPage extends StatelessWidget {
  const FilesPage({
    super.key,
    required this.state,
    required this.onAddMount,
    required this.onOpenMounts,
  });

  final AppState state;
  final VoidCallback onAddMount;
  final VoidCallback onOpenMounts;

  @override
  Widget build(BuildContext context) {
    if (!state.hasMount) {
      return EmptyBlock(
        icon: Icons.cloud_off_rounded,
        title: '还没有挂载',
        subtitle: '接入 FTP / SFTP / S3 / WebDAV，或选择一个本地目录。\n每个挂载可以单独指定代理，互不影响。',
        actionLabel: '添加挂载',
        onAction: onAddMount,
      );
    }
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return Column(
      children: [
        _Header(state: state, onAddMount: onAddMount),
        if (state.loading)
          const LinearProgressIndicator(
            minHeight: 2,
            color: NimboColors.sky600,
            backgroundColor: NimboColors.line2,
          ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _Body(state: state, wide: wide)),
              if (wide && state.selected != null)
                _Details(state: state, entry: state.selected!),
            ],
          ),
        ),
        if (state.tasks.isNotEmpty) _TaskStrip(state: state),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.state, required this.onAddMount});
  final AppState state;
  final VoidCallback onAddMount;

  @override
  Widget build(BuildContext context) {
    final mount = state.activeMount!;
    final segments = splitPath(state.path);
    final title = segments.isEmpty ? mount.name : segments.last;
    final totalSize = state.entries.fold<int>(0, (sum, e) => sum + e.size);

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              InkWell(
                onTap: () => state.cd('/'),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                  child: Row(
                    children: [
                      const Icon(Icons.home_rounded, size: 12, color: NimboColors.ink3),
                      const SizedBox(width: 5),
                      Text(mount.name,
                          style: const TextStyle(
                              fontSize: 10.5, fontWeight: FontWeight.w600, color: NimboColors.ink3)),
                    ],
                  ),
                ),
              ),
              for (var i = 0; i < segments.length; i++) ...[
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 2),
                  child: Text('/', style: TextStyle(fontSize: 10, color: NimboColors.ink4)),
                ),
                InkWell(
                  onTap: () => state.cd('/${segments.take(i + 1).join('/')}'),
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                    child: Text(
                      segments[i],
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: i == segments.length - 1 ? NimboColors.ink2 : NimboColors.ink3,
                      ),
                    ),
                  ),
                ),
              ],
              const Spacer(),
              IconButton(
                tooltip: '刷新',
                onPressed: state.refresh,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                color: NimboColors.ink3,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Flexible(
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NimboText.display),
              ),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  '${state.entries.length} 项 · ${humanBytes(totalSize)}',
                  style: const TextStyle(
                      fontSize: 10.5, fontWeight: FontWeight.w600, color: NimboColors.ink3),
                ),
              ),
              const Spacer(),
              if (!state.readOnly)
                NimboButton('新建文件夹',
                    icon: Icons.create_new_folder_outlined,
                    onPressed: () => _newFolder(context, state)),
              const SizedBox(width: 7),
              NimboButton('挂载管理',
                  kind: NimboButtonKind.ghost,
                  icon: Icons.dns_outlined,
                  onPressed: onAddMount),
            ],
          ),
        ],
      ),
    );
  }
}

Future<void> _newFolder(BuildContext context, AppState state) async {
  final controller = TextEditingController(text: '新建文件夹');
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('新建文件夹', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 320,
        child: TextField(controller: controller, decoration: nimboInput(hint: '文件夹名称')),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text.trim()),
          child: const Text('创建'),
        ),
      ],
    ),
  );
  if (name == null || name.isEmpty) return;
  try {
    await state.createFolder(name);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.state, required this.wide});
  final AppState state;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    if (state.error != null) {
      return EmptyBlock(
        icon: Icons.error_outline_rounded,
        danger: true,
        title: '连接或读取失败',
        subtitle: state.error,
        actionLabel: '重试',
        onAction: state.refresh,
      );
    }
    if (state.entries.isEmpty && !state.loading) {
      return EmptyBlock(
        icon: Icons.folder_open_rounded,
        title: '这里还没有文件',
        subtitle: state.readOnly ? '该挂载为只读' : '新建一个文件夹，或从其他挂载下载到这里',
      );
    }
    return Container(
      margin: const EdgeInsets.fromLTRB(18, 2, 18, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(NimboRadius.panel),
        border: Border.all(color: NimboColors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: const BoxDecoration(
              color: Color(0xFFFCFDFE),
              border: Border(bottom: BorderSide(color: NimboColors.line)),
            ),
            child: const Row(
              children: [
                Expanded(
                  child: Text('名称',
                      style: TextStyle(
                          fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 1, color: NimboColors.ink4)),
                ),
                SizedBox(
                    width: 84,
                    child: Text('大小',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1,
                            color: NimboColors.ink4))),
                SizedBox(width: 116),
                SizedBox(width: 34),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: state.entries.length,
              itemBuilder: (context, i) => _Row(
                state: state,
                entry: state.entries[i],
                selected: state.selected?.path == state.entries[i].path,
                wide: wide,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.state,
    required this.entry,
    required this.selected,
    required this.wide,
  });

  final AppState state;
  final RemoteEntry entry;
  final bool selected;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? const Color(0xFFF3FAFF) : Colors.transparent,
      child: InkWell(
        onTap: () {
          if (entry.isDir) {
            state.cd(entry.path);
          } else if (wide) {
            state.select(entry);
          } else {
            _showActions(context, state, entry);
          }
        },
        onLongPress: () => _showActions(context, state, entry),
        child: Container(
          height: wide ? 44 : 56,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Color(0xFFF0F4F9))),
          ),
          child: Row(
            children: [
              EntryTile(entry: entry, size: wide ? 28 : 34),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w600, color: NimboColors.ink),
                ),
              ),
              SizedBox(
                width: 84,
                child: Text(
                  entry.isDir ? '—' : humanBytes(entry.size),
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w600, color: NimboColors.ink2),
                ),
              ),
              SizedBox(
                width: 116,
                child: Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Text(
                    formatShortDate(entry.modified),
                    style: const TextStyle(
                        fontSize: 10.5, fontWeight: FontWeight.w600, color: NimboColors.ink3),
                  ),
                ),
              ),
              SizedBox(
                width: 34,
                child: PopupMenuButton<String>(
                  tooltip: '更多',
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.more_horiz_rounded, size: 16, color: NimboColors.ink4),
                  onSelected: (v) => _onMenu(context, state, entry, v),
                  itemBuilder: (_) => [
                    if (!entry.isDir)
                      const PopupMenuItem(value: 'download', child: Text('下载', style: TextStyle(fontSize: 12))),
                    if (!state.readOnly) ...[
                      const PopupMenuItem(value: 'rename', child: Text('重命名', style: TextStyle(fontSize: 12))),
                      const PopupMenuItem(value: 'delete', child: Text('删除', style: TextStyle(fontSize: 12))),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

void _onMenu(BuildContext context, AppState state, RemoteEntry entry, String action) {
  switch (action) {
    case 'download':
      state.download(entry);
      break;
    case 'rename':
      _rename(context, state, entry);
      break;
    case 'delete':
      _delete(context, state, entry);
      break;
  }
}

Future<void> _rename(BuildContext context, AppState state, RemoteEntry entry) async {
  final controller = TextEditingController(text: entry.name);
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('重命名', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 360,
        child: TextField(controller: controller, decoration: nimboInput()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('保存')),
      ],
    ),
  );
  if (name == null || name.isEmpty || name == entry.name) return;
  try {
    await state.renameEntry(entry, name);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

Future<void> _delete(BuildContext context, AppState state, RemoteEntry entry) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('删除确认', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
      content: Text('将删除「${entry.name}」${entry.isDir ? '及其全部内容' : ''}，此操作不可撤销。',
          style: const TextStyle(fontSize: 12.5, height: 1.6)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: NimboColors.danger),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  if (ok != true) return;
  try {
    await state.deleteEntry(entry);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

void _showActions(BuildContext context, AppState state, RemoteEntry entry) {
  state.select(entry);
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
            child: Row(
              children: [
                EntryTile(entry: entry, size: 34),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(entry.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                ),
              ],
            ),
          ),
          if (!entry.isDir)
            ListTile(
              leading: const Icon(Icons.download_rounded, size: 20),
              title: const Text('下载', style: TextStyle(fontSize: 13)),
              onTap: () {
                Navigator.pop(ctx);
                state.download(entry);
              },
            ),
          if (!state.readOnly)
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline_rounded, size: 20),
              title: const Text('重命名', style: TextStyle(fontSize: 13)),
              onTap: () {
                Navigator.pop(ctx);
                _rename(context, state, entry);
              },
            ),
          if (!state.readOnly)
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded, size: 20, color: NimboColors.danger),
              title: const Text('删除', style: TextStyle(fontSize: 13, color: NimboColors.danger)),
              onTap: () {
                Navigator.pop(ctx);
                _delete(context, state, entry);
              },
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

class _Details extends StatelessWidget {
  const _Details({required this.state, required this.entry});
  final AppState state;
  final RemoteEntry entry;

  @override
  Widget build(BuildContext context) {
    final mount = state.activeMount!;
    return Container(
      width: 288,
      decoration: const BoxDecoration(
        color: Color(0xFFFCFDFF),
        border: Border(left: BorderSide(color: NimboColors.line)),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('详情',
                    style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.4,
                        color: NimboColors.ink4)),
                const Spacer(),
                InkWell(
                  onTap: () => state.select(null),
                  child: const Icon(Icons.close_rounded, size: 14, color: NimboColors.ink4),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              height: 132,
              width: double.infinity,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFEAF6FF), Color(0xFFE6FBF6)],
                ),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: NimboColors.line),
              ),
              child: Center(child: EntryTile(entry: entry, size: 46)),
            ),
            const SizedBox(height: 12),
            Text(entry.name,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w800, height: 1.35, color: NimboColors.ink)),
            const SizedBox(height: 4),
            Text('${mount.protocol.label}://${mount.subtitle}${entry.path}',
                style: const TextStyle(
                    fontSize: 9, height: 1.6, fontFamily: 'monospace', color: NimboColors.ink4)),
            const SizedBox(height: 12),
            _meta('类型', entry.isDir ? '文件夹' : (entry.extension.isEmpty ? '文件' : entry.extension.toUpperCase())),
            _meta('大小', entry.isDir ? '—' : humanBytes(entry.size)),
            _meta('修改时间', formatDate(entry.modified)),
            _meta('挂载', mount.name),
            _meta('权限', mount.readOnly ? '只读' : '可读写'),
            const SizedBox(height: 14),
            if (!entry.isDir)
              SizedBox(
                width: double.infinity,
                child: NimboButton('下载到本地',
                    icon: Icons.download_rounded,
                    kind: NimboButtonKind.primary,
                    height: 34,
                    expand: true,
                    onPressed: () => state.download(entry)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _meta(String label, String value) => Container(
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xFFF0F4F9))),
        ),
        child: Row(
          children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 10.5, fontWeight: FontWeight.w600, color: NimboColors.ink3)),
            const Spacer(),
            Flexible(
              child: Text(value,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                      fontSize: 10.5, fontWeight: FontWeight.w700, color: NimboColors.ink)),
            ),
          ],
        ),
      );
}

class _TaskStrip extends StatelessWidget {
  const _TaskStrip({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final running = state.tasks.where((t) => t.status == TransferStatus.running).toList();
    final latest = state.tasks.first;
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: NimboColors.line)),
      ),
      child: Row(
        children: [
          const Icon(Icons.swap_vert_rounded, size: 16, color: NimboColors.sky600),
          const SizedBox(width: 8),
          Text(
            running.isEmpty ? '最近任务' : '传输中 ${running.length}',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: NimboColors.ink),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(latest.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                const SizedBox(height: 5),
                ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: LinearProgressIndicator(
                    value: latest.status == TransferStatus.done ? 1 : latest.progress,
                    minHeight: 4,
                    backgroundColor: NimboColors.line2,
                    color: latest.status == TransferStatus.failed
                        ? NimboColors.danger
                        : NimboColors.sky600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Text(
            latest.status == TransferStatus.failed
                ? (latest.error ?? '失败')
                : '${humanBytes(latest.transferred)} / ${humanBytes(latest.total)}',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: latest.status == TransferStatus.failed
                  ? NimboColors.dangerInk
                  : NimboColors.ink3,
            ),
          ),
          const SizedBox(width: 8),
          InkWell(
            onTap: state.clearFinishedTasks,
            child: const Padding(
              padding: EdgeInsets.all(6),
              child: Icon(Icons.close_rounded, size: 14, color: NimboColors.ink4),
            ),
          ),
        ],
      ),
    );
  }
}
