import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../core/format.dart';
import '../core/models.dart';
import '../drivers/errors.dart';
import '../state/app_state.dart';
import '../ui/kit.dart';

/// 目标选择结果：某个挂载内的某个目录。
class PickTarget {
  const PickTarget(this.mount, this.path);

  final Mount mount;
  final String path;

  String get label => path == '/' ? '${mount.name}/' : '${mount.name}$path';
}

/// 弹出「复制到 / 移动到」的目标目录选择器；取消返回 null。
///
/// 选择器自己拿 `AppState.sessionFor()` 取会话，所以**可以选别的挂载**：
/// 目标挂载没连过时按需建立，用完不销毁（多挂载常驻连接）。
Future<PickTarget?> pickDestination(
  BuildContext context,
  AppState state, {
  required bool move,
}) {
  return showDialog<PickTarget>(
    context: context,
    builder: (_) => _DestinationDialog(state: state, move: move),
  );
}

class _DestinationDialog extends StatefulWidget {
  const _DestinationDialog({required this.state, required this.move});

  final AppState state;
  final bool move;

  @override
  State<_DestinationDialog> createState() => _DestinationDialogState();
}

class _DestinationDialogState extends State<_DestinationDialog> {
  Mount? _mount;
  String _path = '/';
  List<RemoteEntry> _dirs = const [];
  bool _loading = false;
  String? _error;

  Future<void> _openMount(Mount m) async {
    setState(() {
      _mount = m;
      _path = '/';
      _dirs = const [];
      _error = null;
    });
    await _load();
  }

  Future<void> _load() async {
    final m = _mount;
    if (m == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await widget.state.sessionFor(m);
      final all = await d.list(_path);
      final hide = widget.state.settings.hideHiddenFiles;
      final dirs = all
          .where((e) => e.isDir && (!hide || !e.name.startsWith('.')))
          .toList(growable: false);
      if (!mounted) return;
      setState(() => _dirs = dirs);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _enter(RemoteEntry dir) async {
    _path = normalizePath(dir.path);
    await _load();
  }

  Future<void> _up() async {
    if (_path == '/') {
      setState(() {
        _mount = null;
        _dirs = const [];
        _error = null;
      });
      return;
    }
    _path = parentPath(_path);
    await _load();
  }

  void _confirm() {
    final m = _mount;
    if (m == null) return;
    Navigator.of(context).pop(PickTarget(m, _path));
  }

  @override
  Widget build(BuildContext context) {
    final move = widget.move;
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(NimboRadius.card)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 10, 8),
              child: Row(
                children: [
                  Icon(move ? Icons.drive_file_move_outline : Icons.copy_all_rounded,
                      size: 16, color: NimboColors.sky700),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(move ? '移动到…' : '复制到…',
                        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800)),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, size: 16, color: NimboColors.ink3),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: NimboColors.line),
            if (_mount != null) _crumbBar(),
            Expanded(child: _body()),
            const Divider(height: 1, color: NimboColors.line),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _mount == null ? '先在左侧选一个挂载' : '目标：${PickTarget(_mount!, _path).label}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 10, fontWeight: FontWeight.w600, color: NimboColors.ink3),
                    ),
                  ),
                  NimboButton('取消',
                      kind: NimboButtonKind.ghost, height: 28, onPressed: () => Navigator.of(context).pop()),
                  const SizedBox(width: 8),
                  NimboButton(move ? '移动到这里' : '复制到这里',
                      kind: NimboButtonKind.primary,
                      height: 28,
                      icon: move ? Icons.drive_file_move_outline : Icons.copy_all_rounded,
                      onPressed: _mount == null ? null : _confirm),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 面包屑：点「…/挂载名」可以逐级退回（退到根再退就是挂载列表）。
  Widget _crumbBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
      decoration: const BoxDecoration(
        color: Color(0xFFFCFDFE),
        border: Border(bottom: BorderSide(color: NimboColors.line)),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: '上一级',
            visualDensity: VisualDensity.compact,
            onPressed: _up,
            icon: const Icon(Icons.arrow_upward_rounded, size: 15, color: NimboColors.ink3),
          ),
          const SizedBox(width: 2),
          Expanded(
            child: Text(
              '${_mount!.name}${_path == '/' ? '/' : _path}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 10.5, fontWeight: FontWeight.w700, color: NimboColors.ink2),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(
          child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)));
    }
    final err = _error;
    if (err != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(err,
            style: const TextStyle(fontSize: 11, height: 1.6, color: NimboColors.dangerInk)),
      );
    }
    if (_mount == null) {
      final mounts = widget.state.mounts;
      if (mounts.isEmpty) {
        return const Padding(
          padding: EdgeInsets.all(16),
          child: Text('还没有挂载', style: TextStyle(fontSize: 11.5, color: NimboColors.ink3)),
        );
      }
      return ListView(
        padding: const EdgeInsets.symmetric(vertical: 4),
        children: [
          for (final m in mounts)
            _Row(
              icon: Icons.cloud_outlined,
              title: m.name,
              subtitle: '${m.protocol.label} · ${m.subtitle}',
              onTap: () => _openMount(m),
            ),
        ],
      );
    }
    if (_dirs.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('这个目录下没有子目录，可以复制/移动到这里',
            style: TextStyle(fontSize: 11, height: 1.6, color: NimboColors.ink3)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _dirs.length,
      itemBuilder: (_, i) {
        final dir = _dirs[i];
        return _Row(
          icon: Icons.folder_outlined,
          title: dir.name,
          onTap: () => _enter(dir),
        );
      },
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.title, this.subtitle, required this.onTap});

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final sub = subtitle;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 16, color: NimboColors.ink3),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                  if (sub != null)
                    Text(sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 9.5, color: NimboColors.ink4)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, size: 16, color: NimboColors.ink4),
          ],
        ),
      ),
    );
  }
}
