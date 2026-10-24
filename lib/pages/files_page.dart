import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../core/format.dart';
import '../core/models.dart';
import '../drivers/errors.dart';
import '../state/app_state.dart';
import '../ui/kit.dart';
import 'pick_destination.dart';
import 'preview_page.dart';

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
    if (state.browseAll) {
      return _AllMounts(state: state, onAddMount: onAddMount);
    }
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return Column(
      children: [
        _Header(state: state, onAddMount: onAddMount, compact: !wide),
        if (state.loading)
          const LinearProgressIndicator(
            minHeight: 2,
            color: NimboColors.sky600,
            backgroundColor: NimboColors.line2,
          ),
        if (state.selectionMode) _SelectionBar(state: state),
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

/// 「全部挂载」根：所有挂载的入口。点击卡片才进入该挂载的目录树。
class _AllMounts extends StatelessWidget {
  const _AllMounts({required this.state, required this.onAddMount});
  final AppState state;
  final VoidCallback onAddMount;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('全部挂载', style: NimboText.display),
                  const SizedBox(height: 3),
                  Text(
                    '${state.mounts.length} 个挂载 · 点击进入',
                    style: const TextStyle(
                        fontSize: 10.5, fontWeight: FontWeight.w600, color: NimboColors.ink3),
                  ),
                ],
              ),
              const Spacer(),
              NimboButton('添加挂载',
                  kind: NimboButtonKind.primary,
                  icon: Icons.add_rounded,
                  onPressed: onAddMount),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: EdgeInsets.fromLTRB(18, 0, 18, state.tasks.isEmpty ? 18 : 8),
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: wide ? 340 : 560,
              // 卡片里有 3 行文字，字号放大后固定 104 会把最后一行挤出去。
              mainAxisExtent: uiSize(104),
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
            ),
            itemCount: state.mounts.length,
            itemBuilder: (_, i) => _MountCard(state: state, mount: state.mounts[i]),
          ),
        ),
        if (state.tasks.isNotEmpty) _TaskStrip(state: state),
      ],
    );
  }
}

class _MountCard extends StatelessWidget {
  const _MountCard({required this.state, required this.mount});
  final AppState state;
  final Mount mount;

  static IconData _icon(MountProtocol p) => switch (p) {
        MountProtocol.ftp => Icons.swap_horiz_rounded,
        MountProtocol.sftp => Icons.terminal_rounded,
        MountProtocol.s3 => Icons.cloud_outlined,
        MountProtocol.webdav => Icons.language_rounded,
        MountProtocol.local => Icons.folder_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final isActive = state.activeId == mount.id;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(NimboRadius.panel),
        border: Border.all(color: isActive ? const Color(0xFFBFE4F8) : NimboColors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => state.open(mount),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: uiSize(38),
                height: uiSize(38),
                decoration: BoxDecoration(
                    color: mount.protocol.bg,
                    borderRadius: BorderRadius.circular(11)),
                child: Icon(_icon(mount.protocol),
                    size: uiSize(19), color: mount.protocol.color),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            mount.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12.5, fontWeight: FontWeight.w800, color: NimboColors.ink),
                          ),
                        ),
                        const SizedBox(width: 6),
                        ProtocolBadge(mount.protocol, compact: true),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      mount.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 10,
                          fontFamily: 'monospace',
                          color: NimboColors.ink3),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        StatusDot(
                            color: state.isConnected(mount.id)
                                ? NimboColors.ok
                                : const Color(0xFFB6C6D6),
                            size: 5),
                        const SizedBox(width: 5),
                        Text(
                          // 多个挂载是「同时在线」的，所以除了「当前浏览」还要标出连接状态。
                          isActive
                              ? '当前浏览'
                              : '${mount.protocol.label} · '
                                  '${state.isConnected(mount.id) ? '已连接' : '未连接'}',
                          style: const TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w600,
                              color: NimboColors.ink3),
                        ),
                        if (mount.proxy.enabled) ...[
                          const SizedBox(width: 8),
                          const Icon(Icons.shield_outlined, size: 10, color: NimboColors.ink4),
                          const SizedBox(width: 3),
                          Text(mount.proxy.type.label,
                              style: const TextStyle(fontSize: 9.5, color: NimboColors.ink3)),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, size: 17, color: NimboColors.ink4),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.state, required this.onAddMount, this.compact = false});
  final AppState state;
  final VoidCallback onAddMount;
  final bool compact;

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
              // 路径层级深 + 字号放大后，面包屑很容易顶破一行：改成横向可滚动，
              // reverse 让「当前目录」这一段始终可见（而不是被挤到右侧外面）。
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  reverse: true,
                  child: Row(
                    children: [
                      InkWell(
                        onTap: state.showAll,
                        borderRadius: BorderRadius.circular(6),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                          child: Row(
                            children: [
                              Icon(Icons.apps_rounded, size: 12, color: NimboColors.ink3),
                              SizedBox(width: 5),
                              Text('全部挂载',
                                  style: TextStyle(
                                      fontSize: 10.5, fontWeight: FontWeight.w600, color: NimboColors.ink3)),
                            ],
                          ),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 2),
                        child: Text('/', style: TextStyle(fontSize: 10, color: NimboColors.ink4)),
                      ),
                      InkWell(
                        onTap: () => state.cd('/'),
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                          child: Row(
                            children: [
                              const Icon(Icons.folder_outlined, size: 11, color: NimboColors.ink3),
                              const SizedBox(width: 5),
                              Text(mount.name,
                                  style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w600,
                                      color: segments.isEmpty ? NimboColors.ink2 : NimboColors.ink3)),
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
                    ],
                  ),
                ),
              ),
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
              // 标题与统计合成一列并占满剩余宽度：窄屏 + 放大字号时按钮不会被顶出去，
              // 也不会出现「标题和统计各占 1/3、按钮前留白」的怪比例。
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: NimboText.display),
                    const SizedBox(height: 2),
                    Text(
                      // 容量只在协议支持时出现（WebDAV quota / SFTP statvfs），否则省略。
                      '${state.entries.length} 项 · ${humanBytes(totalSize)}'
                      '${state.space == null ? '' : ' · 剩余 ${humanBytes(state.space!.free)}'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 10.5, fontWeight: FontWeight.w600, color: NimboColors.ink3),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              // 返回上层：**只在桌面端**出现（移动端有系统返回键与侧滑返回，且标题行
              // 宽度本来就紧张，多加一个按钮会把「上传 / 新建」挤出去）。
              // 停在「全部挂载」聚合根时没有上层，置灰不可点。
              if (!compact) ...[
                NimboButton('返回上层',
                    icon: Icons.arrow_upward_rounded,
                    onPressed: state.browseAll ? null : () => state.up()),
                const SizedBox(width: 7),
              ],
              _UploadButton(state: state),
              const SizedBox(width: 7),
              NimboButton(compact ? '新建' : '新建文件夹',
                  icon: Icons.create_new_folder_outlined,
                  onPressed: () => _newFolder(context, state)),
              const SizedBox(width: 7),
              NimboButton('选择',
                  icon: Icons.checklist_rounded,
                  onPressed: state.entries.isEmpty ? null : () => state.beginSelection()),
              if (!compact) ...[
                const SizedBox(width: 7),
                NimboButton('挂载管理',
                    kind: NimboButtonKind.ghost,
                    icon: Icons.dns_outlined,
                    onPressed: onAddMount),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _UploadButton extends StatelessWidget {
  const _UploadButton({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '上传',
      offset: const Offset(0, 34),
      onSelected: (v) {
        if (v == 'files') _upload(context, state);
        if (v == 'folder') _uploadFolder(context, state);
      },
      // 不能是 const 列表：高度由 uiSize() 在运行时按平台换算。
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'files',
          height: uiSize(38),
          child: Row(children: [
            Icon(Icons.insert_drive_file_outlined, size: 15, color: NimboColors.ink3),
            SizedBox(width: 8),
            Text('上传文件', style: TextStyle(fontSize: 12)),
          ]),
        ),
        PopupMenuItem(
          value: 'folder',
          height: uiSize(38),
          child: Row(children: [
            Icon(Icons.folder_copy_outlined, size: 15, color: NimboColors.ink3),
            SizedBox(width: 8),
            Text('上传文件夹', style: TextStyle(fontSize: 12)),
          ]),
        ),
      ],
      child: Container(
        height: uiSize(30),
        padding: EdgeInsets.symmetric(horizontal: uiSize(11)),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          gradient: NimboColors.gradient,
          boxShadow: const [
            BoxShadow(color: Color(0x400EA5E9), blurRadius: 12, offset: Offset(0, 4)),
          ],
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.upload_rounded, size: 14, color: Colors.white),
            SizedBox(width: 5),
            Text('上传',
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Colors.white)),
            SizedBox(width: 1),
            Icon(Icons.expand_more_rounded, size: 14, color: Colors.white),
          ],
        ),
      ),
    );
  }
}

class _SelectionBar extends StatelessWidget {
  const _SelectionBar({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final n = state.pickedCount;
    final all = state.entries.isNotEmpty && n >= state.entries.length;
    return Container(
      height: uiSize(44),
      margin: const EdgeInsets.fromLTRB(18, 0, 18, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF8FF),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFCFE8FA)),
      ),
      child: Row(
        children: [
          const Icon(Icons.checklist_rounded, size: 15, color: NimboColors.sky700),
          const SizedBox(width: 7),
          // 可收缩：窄屏 + 放大字号时先截断提示语，保证右侧按钮完整可见。
          Flexible(
            child: Text(
              n == 0 ? '选择要操作的项目' : '已选 $n 项',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 11.5, fontWeight: FontWeight.w700, color: NimboColors.sky700),
            ),
          ),
          const SizedBox(width: 12),
          InkWell(
            onTap: () => all ? state.exitSelection() : state.pickAll(),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
              child: Text(all ? '取消全选' : '全选',
                  style: const TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w600, color: NimboColors.ink3)),
            ),
          ),
          const Spacer(),
          // 复制/移动放溢出菜单：多选条在手机上本来就窄，再摆两个按钮会挤掉文字。
          PopupMenuButton<String>(
            tooltip: '更多操作',
            padding: EdgeInsets.zero,
            enabled: n > 0,
            icon: const Icon(Icons.more_horiz_rounded, size: 16, color: NimboColors.ink3),
            onSelected: (v) {
              final items = state.pickedEntries;
              if (items.isEmpty) return;
              _copyMoveTo(context, state, items, move: v == 'move');
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'copy', child: Text('复制到…', style: TextStyle(fontSize: 12))),
              PopupMenuItem(value: 'move', child: Text('移动到…', style: TextStyle(fontSize: 12))),
            ],
          ),
          const SizedBox(width: 4),
          NimboButton('下载',
              kind: NimboButtonKind.secondary,
              icon: Icons.download_rounded,
              onPressed: n == 0 ? null : () => _downloadPicked(context)),
          const SizedBox(width: 6),
          NimboButton('删除',
              kind: NimboButtonKind.danger,
              icon: Icons.delete_outline_rounded,
              onPressed: n == 0 ? null : () => _deletePicked(context)),
          const SizedBox(width: 4),
          IconButton(
            tooltip: '退出多选',
            visualDensity: VisualDensity.compact,
            onPressed: state.exitSelection,
            icon: const Icon(Icons.close_rounded, size: 16, color: NimboColors.ink3),
          ),
        ],
      ),
    );
  }

  Future<void> _downloadPicked(BuildContext context) async {
    final dirs = state.pickedEntries.where((e) => e.isDir).length;
    final n = await state.downloadPicked();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(dirs == 0
          ? '已加入下载队列：$n 个文件'
          : '已加入下载队列：$n 个文件（$dirs 个文件夹已递归展开）'),
    ));
  }

  Future<void> _deletePicked(BuildContext context) async {
    final n = state.pickedCount;
    final ok = await _confirmDelete(
        context, state, n == 1 ? '「${state.pickedEntries.first.name}」' : '$n 项');
    if (ok != true) return;
    try {
      final done = await state.deletePicked();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已删除 $done 项')));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

Future<void> _uploadFolder(BuildContext context, AppState state) async {
  try {
    final dir = await FilePicker.platform.getDirectoryPath(dialogTitle: '选择要上传的文件夹');
    if (dir == null || dir.isEmpty) return;
    final n = await state.uploadFolder(dir);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(n == 0 ? '该文件夹内没有可上传的文件' : '已加入上传队列：$n 个文件'),
    ));
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
  }
}

Future<void> _upload(BuildContext context, AppState state) async {
  try {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null) return;
    final paths = <String>[];
    for (final f in result.files) {
      final p = f.path;
      if (p != null && p.isNotEmpty) paths.add(p);
    }
    if (paths.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('没有拿到可读取的本地路径')));
      }
      return;
    }
    await state.uploadFiles(paths);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
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

class _Body extends StatefulWidget {
  const _Body({required this.state, required this.wide});
  final AppState state;
  final bool wide;

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return DropTarget(
      enable: true,
      onDragEntered: (_) => setState(() => _hover = true),
      onDragExited: (_) => setState(() => _hover = false),
      onDragDone: (details) async {
        if (mounted) setState(() => _hover = false);
        await _handleDrop(context, state, details);
      },
      child: Stack(
        children: [
          Positioned.fill(child: _content(context, state)),
          if (_hover)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  margin: const EdgeInsets.fromLTRB(18, 2, 18, 10),
                  decoration: BoxDecoration(
                    color: const Color(0xF2EFF8FF),
                    borderRadius: BorderRadius.circular(NimboRadius.panel),
                    border: Border.all(color: NimboColors.sky600, width: 1.4),
                  ),
                  child: const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.upload_file_rounded, size: 26, color: NimboColors.sky600),
                        SizedBox(height: 8),
                        Text('松手即上传到当前目录',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: NimboColors.sky700)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 拖入的内容：0.8.x 只解析本地文件，直接取 XFile.path 入队。
  Future<void> _handleDrop(BuildContext context, AppState state, DropDoneDetails details) async {
    final paths = <String>[];
    for (final file in details.files) {
      final p = file.path;
      if (p.isNotEmpty) paths.add(p);
    }
    if (paths.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('没有识别到可上传的文件')));
      }
      return;
    }
    await state.uploadFiles(paths);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已加入上传队列：${paths.length} 个文件')));
    }
  }

  Widget _content(BuildContext context, AppState state) {
    final wide = widget.wide;
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
        subtitle: '新建一个文件夹，或把文件拖到这里上传',
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
            height: uiSize(30),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: const BoxDecoration(
              color: Color(0xFFFCFDFE),
              border: Border(bottom: BorderSide(color: NimboColors.line)),
            ),
            child: Row(
              children: [
                const Expanded(
                  child: Text('名称',
                      style: TextStyle(
                          fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 1, color: NimboColors.ink4)),
                ),
                SizedBox(
                    width: wide ? 84 : 64,
                    child: const Text('大小',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1,
                            color: NimboColors.ink4))),
                // 移动端不显示「修改时间」列：字号放大后它会把文件名挤没。
                if (wide) const SizedBox(width: 116),
                const SizedBox(width: 34),
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
    final picked = state.selectionMode && state.isPicked(entry);
    return Material(
      color: picked ? const Color(0xFFEFF8FF) : (selected ? const Color(0xFFF3FAFF) : Colors.transparent),
      child: InkWell(
        onTap: () {
          if (state.selectionMode) {
            state.togglePicked(entry);
            return;
          }
          if (entry.isDir) {
            state.cd(entry.path);
          } else if (wide) {
            state.select(entry);
          } else {
            _showActions(context, state, entry);
          }
        },
        onLongPress: () {
          if (state.selectionMode) {
            state.togglePicked(entry);
            return;
          }
          // 长按进入多选（移动端主要入口）；单项操作走行尾「更多」菜单。
          state.beginSelection(entry);
        },
        child: Container(
          // 行高跟着字号放大，否则放大后的文件名会被裁。
          height: uiSize(wide ? 44 : 56),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Color(0xFFF0F4F9))),
          ),
          child: Row(
            children: [
              if (state.selectionMode) ...[
                _PickBox(checked: state.isPicked(entry), onTap: () => state.togglePicked(entry)),
                const SizedBox(width: 7),
              ],
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
                width: wide ? 84 : 64,
                child: Text(
                  entry.isDir ? '—' : humanBytes(entry.size),
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w600, color: NimboColors.ink2),
                ),
              ),
              // 移动端让出这一列，宽度全给文件名（放大字号后尤其重要）。
              if (wide)
                SizedBox(
                  width: 116,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Text(
                      formatShortDate(entry.modified),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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
                    if (!entry.isDir && canPreviewEntry(entry))
                      const PopupMenuItem(
                          value: 'preview', child: Text('预览', style: TextStyle(fontSize: 12))),
                    PopupMenuItem(
                        value: 'download',
                        child: Text(entry.isDir ? '下载文件夹' : '下载',
                            style: const TextStyle(fontSize: 12))),
                    const PopupMenuItem(value: 'rename', child: Text('重命名', style: TextStyle(fontSize: 12))),
                    const PopupMenuItem(value: 'copy', child: Text('复制到…', style: TextStyle(fontSize: 12))),
                    const PopupMenuItem(value: 'move', child: Text('移动到…', style: TextStyle(fontSize: 12))),
                    const PopupMenuItem(value: 'delete', child: Text('删除', style: TextStyle(fontSize: 12))),
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

/// 复制/移动：先选目标目录（可选别的挂载），再交给 `AppState.copyOrMoveEntries`。
///
/// 成功后退多选并提示处理了多少个文件；失败用 `describeError` 给可读原因。
Future<void> _copyMoveTo(
  BuildContext context,
  AppState state,
  List<RemoteEntry> entries, {
  required bool move,
}) async {
  if (entries.isEmpty) return;
  final target = await pickDestination(context, state, move: move);
  if (target == null || !context.mounted) return;
  try {
    final n = await state.copyOrMoveEntries(
      entries,
      targetMount: target.mount,
      targetPath: target.path,
      move: move,
    );
    if (state.selectionMode) state.exitSelection();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(move ? '已移动 $n 个文件到 ${target.label}' : '已复制 $n 个文件到 ${target.label}'),
    ));
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(describeError(e))));
  }
}

void _onMenu(BuildContext context, AppState state, RemoteEntry entry, String action) {
  switch (action) {
    case 'preview':
      showPreview(context, state, entry);
      break;
    case 'download':
      state.download(entry);
      break;
    case 'rename':
      _rename(context, state, entry);
      break;
    case 'copy':
      _copyMoveTo(context, state, [entry], move: false);
      break;
    case 'move':
      _copyMoveTo(context, state, [entry], move: true);
      break;
    case 'delete':
      _delete(context, state, entry);
      break;
  }
}

class _PickBox extends StatelessWidget {
  const _PickBox({required this.checked, required this.onTap});
  final bool checked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(5),
      child: Container(
        width: uiSize(17),
        height: uiSize(17),
        decoration: BoxDecoration(
          color: checked ? NimboColors.sky600 : Colors.white,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
              color: checked ? NimboColors.sky600 : const Color(0xFFCFDCE8), width: 1.3),
        ),
        child: checked
            ? Icon(Icons.check_rounded, size: uiSize(12), color: Colors.white)
            : null,
      ),
    );
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

Future<bool?> _confirmDelete(BuildContext context, AppState state, String target) {
  if (!state.settings.confirmDelete) return Future.value(true);
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('删除确认', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
      content: Text('将删除 $target，此操作不可撤销。',
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
}

Future<void> _delete(BuildContext context, AppState state, RemoteEntry entry) async {
  final ok = await _confirmDelete(
      context, state, '「${entry.name}」${entry.isDir ? '及其全部内容' : ''}');
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
          if (!entry.isDir && canPreviewEntry(entry))
            ListTile(
              leading: const Icon(Icons.visibility_outlined, size: 20),
              title: const Text('预览', style: TextStyle(fontSize: 13)),
              onTap: () {
                Navigator.pop(ctx);
                showPreview(context, state, entry);
              },
            ),
          ListTile(
            leading: Icon(
                entry.isDir ? Icons.download_for_offline_outlined : Icons.download_rounded,
                size: 20),
            title: Text(entry.isDir ? '下载文件夹' : '下载', style: const TextStyle(fontSize: 13)),
            onTap: () {
              Navigator.pop(ctx);
              state.download(entry);
            },
          ),
          ListTile(
            leading: const Icon(Icons.drive_file_rename_outline_rounded, size: 20),
            title: const Text('重命名', style: TextStyle(fontSize: 13)),
            onTap: () {
              Navigator.pop(ctx);
              _rename(context, state, entry);
            },
          ),
          ListTile(
            leading: const Icon(Icons.copy_all_rounded, size: 20),
            title: const Text('复制到…', style: TextStyle(fontSize: 13)),
            onTap: () {
              Navigator.pop(ctx);
              _copyMoveTo(context, state, [entry], move: false);
            },
          ),
          ListTile(
            leading: const Icon(Icons.drive_file_move_outline, size: 20),
            title: const Text('移动到…', style: TextStyle(fontSize: 13)),
            onTap: () {
              Navigator.pop(ctx);
              _copyMoveTo(context, state, [entry], move: true);
            },
          ),
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
            const SizedBox(height: 14),
            if (!entry.isDir)
              SizedBox(
                width: double.infinity,
                child: NimboButton('预览',
                    icon: Icons.visibility_outlined,
                    height: 34,
                    expand: true,
                    onPressed: canPreviewEntry(entry)
                        ? () => showPreview(context, state, entry)
                        : null),
              ),
            if (!entry.isDir) const SizedBox(height: 6),
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
    final runners = state.tasks.where((t) => t.status == TransferStatus.running).toList();
    final queued = state.tasks.where((t) => t.status == TransferStatus.queued).length;
    final latest = state.tasks.first;
    final failed = latest.status == TransferStatus.failed;
    final done = latest.status == TransferStatus.done;
    final color = failed
        ? NimboColors.danger
        : done
            ? NimboColors.ok
            : NimboColors.sky600;

    final detail = failed
        ? (latest.error ?? '失败')
        : done
            ? '已完成 · ${humanBytes(latest.total)}'
            : '${humanBytes(latest.transferred)} / ${latest.total > 0 ? humanBytes(latest.total) : '未知'}'
                '${latest.speed > 0 ? ' · ${humanSpeed(latest.speed)}' : ''}';

    return Container(
      height: uiSize(58),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: NimboColors.line)),
      ),
      child: Row(
        children: [
          Icon(
            latest.dir == TransferDir.upload ? Icons.upload_rounded : Icons.download_rounded,
            size: 16,
            color: NimboColors.sky600,
          ),
          const SizedBox(width: 8),
          Text(
            runners.isEmpty
                ? '最近任务'
                : '传输中 ${runners.length}${queued > 0 ? ' · 排队 $queued' : ''}',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: NimboColors.ink),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(latest.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      latest.dir == TransferDir.upload
                          ? Icons.north_east_rounded
                          : Icons.south_west_rounded,
                      size: 10,
                      color: NimboColors.ink4,
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: LinearProgressIndicator(
                    value: done ? 1 : latest.indicatorValue,
                    minHeight: 4,
                    backgroundColor: NimboColors.line2,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: Text(
              detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: failed ? NimboColors.dangerInk : NimboColors.ink3,
              ),
            ),
          ),
          const SizedBox(width: 4),
          if (latest.status == TransferStatus.running || latest.status == TransferStatus.queued)
            _iconBtn(Icons.pause_rounded, '暂停', () => state.transfers.toggle(latest)),
          if (latest.status == TransferStatus.paused || failed)
            _iconBtn(Icons.refresh_rounded, '重试', () => state.transfers.toggle(latest)),
          _iconBtn(Icons.close_rounded, '移除', () => state.transfers.cancel(latest)),
        ],
      ),
    );
  }

  Widget _iconBtn(IconData icon, String tip, VoidCallback onTap) => Tooltip(
        message: tip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(icon, size: 14, color: NimboColors.ink4),
          ),
        ),
      );
}
