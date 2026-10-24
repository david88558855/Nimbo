import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../core/models.dart';
import '../drivers/errors.dart';
import '../state/app_state.dart';
import '../ui/kit.dart';
import 'add_mount_page.dart';

class MountsPage extends StatelessWidget {
  const MountsPage({
    super.key,
    required this.state,
    required this.onAddMount,
    required this.onOpenFiles,
  });

  final AppState state;
  final VoidCallback onAddMount;
  final VoidCallback onOpenFiles;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // 窄屏 + 放大字号时说明文字自动换行，按钮不会被顶出去。
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('挂载管理', style: NimboText.display),
                    SizedBox(height: 4),
                    Text('协议差异集中在这里，文件页保持同构',
                        style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: NimboColors.ink3)),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              NimboButton('添加挂载',
                  kind: NimboButtonKind.primary, icon: Icons.add_rounded, onPressed: onAddMount),
            ],
          ),
        ),
        Expanded(
          child: state.mounts.isEmpty
              ? EmptyBlock(
                  icon: Icons.dns_outlined,
                  title: '还没有挂载',
                  subtitle: '接入 FTP / SFTP / S3 / WebDAV，或选择一个本地目录。',
                  actionLabel: '添加挂载',
                  onAction: onAddMount,
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                  itemBuilder: (context, i) {
                    final m = state.mounts[i];
                    return _MountCard(
                      mount: m,
                      active: m.id == state.activeId,
                      onOpen: () {
                        state.open(m);
                        onOpenFiles();
                      },
                      onEdit: () => _openEdit(context, m),
                      onTest: () => state.testSavedMount(m),
                      onDelete: () => _confirmDelete(context, m),
                    );
                  },
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemCount: state.mounts.length,
                ),
        ),
      ],
    );
  }

  /// 编辑：复用添加弹窗（字段预填、密码留空不改）。改完就地刷新列表。
  Future<void> _openEdit(BuildContext context, Mount mount) async {
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AddMountDialog(state: state, existing: mount),
    );
    if (changed == true && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('挂载已更新')));
    }
  }

  Future<void> _confirmDelete(BuildContext context, Mount mount) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除挂载', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
        content: Text('将从本机移除「${mount.name}」的配置与凭据，不会删除远端任何数据。',
            style: const TextStyle(fontSize: 12.5, height: 1.6)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: NimboColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (ok == true) await state.removeMount(mount);
  }
}

class _MountCard extends StatefulWidget {
  const _MountCard({
    required this.mount,
    required this.active,
    required this.onOpen,
    required this.onEdit,
    required this.onTest,
    required this.onDelete,
  });

  final Mount mount;
  final bool active;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final Future<int> Function() onTest;
  final VoidCallback onDelete;

  @override
  State<_MountCard> createState() => _MountCardState();
}

class _MountCardState extends State<_MountCard> {
  bool _testing = false;
  bool _ok = false;
  String? _result;

  Mount get mount => widget.mount;

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _result = null;
    });
    try {
      final count = await widget.onTest();
      if (!mounted) return;
      setState(() {
        _ok = true;
        _result = '连接成功 · 根目录 $count 项';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ok = false;
        _result = describeError(e);
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(NimboRadius.panel),
        border: Border.all(color: widget.active ? const Color(0xFFBAE6FD) : NimboColors.line),
      ),
      // 宽屏：信息在左、操作在右，整行垂直居中；窄屏：操作换到下一行右对齐。
      child: LayoutBuilder(builder: (context, box) {
        final tight = box.maxWidth < 560;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (tight) ...[
              _info(),
              const SizedBox(height: 10),
              Align(alignment: Alignment.centerRight, child: _actions()),
            ] else
              Row(
                children: [
                  Expanded(child: _info()),
                  const SizedBox(width: 14),
                  _actions(),
                ],
              ),
            if (_result != null) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: _ok ? const Color(0x1422C55E) : const Color(0x14F43F5E),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: _ok ? const Color(0x3322C55E) : const Color(0x33F43F5E)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(_ok ? Icons.check_circle_outline : Icons.error_outline,
                        size: 13, color: _ok ? NimboColors.okInk : NimboColors.dangerInk),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(_result!,
                          style: TextStyle(
                              fontSize: 10.5,
                              height: 1.5,
                              fontWeight: FontWeight.w600,
                              color: _ok ? NimboColors.okInk : NimboColors.dangerInk)),
                    ),
                  ],
                ),
              ),
            ],
          ],
        );
      }),
    );
  }

  /// 左侧信息区：协议徽标 + 名称 / 地址 / 连接方式，三行紧凑排列。
  Widget _info() {
    // 用类里的 `mount` getter（= widget.mount），避免多一个同义局部变量。
    final address = mount.protocol == MountProtocol.local
        ? mount.rootPath
        : '${mount.host}${mount.port > 0 ? ':${mount.port}' : ''}'
            '${mount.protocol == MountProtocol.s3 && mount.bucket.isNotEmpty ? ' / ${mount.bucket}' : ''}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            ProtocolBadge(mount.protocol),
            const SizedBox(width: 8),
            Flexible(
              child: Text(mount.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
            ),
            if (widget.active) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                decoration: BoxDecoration(
                  color: NimboColors.navOnBg,
                  borderRadius: BorderRadius.circular(5),
                ),
                child: const Text('当前',
                    style: TextStyle(
                        fontSize: 8.5, fontWeight: FontWeight.w800, color: NimboColors.navOn)),
              ),
            ],
          ],
        ),
        const SizedBox(height: 5),
        Text(
          address,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
              fontSize: 10, fontFamily: 'monospace', color: NimboColors.ink3, height: 1.5),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Icon(
              mount.proxy.enabled ? Icons.link_rounded : Icons.link_off,
              size: 12,
              color: mount.proxy.enabled ? NimboColors.sky700 : NimboColors.ink4,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                mount.proxy.enabled ? '经 ${mount.proxy.label}（仅本挂载）' : '直连',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: mount.proxy.enabled ? NimboColors.sky700 : NimboColors.ink4),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 右侧操作区：四个按钮统一 28 高（原来 26 高且与卡片高度不匹配）。
  ///
  /// 顺序固定「测试连接 → 编辑 → 打开 │ 删除」：主操作「打开」用主色，
  /// 「删除」用浅红底红字并隔一条竖线，避免误点。
  Widget _actions() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        NimboButton(_testing ? '测试中…' : '测试连接',
            kind: NimboButtonKind.ghost,
            height: 28,
            onPressed: _testing ? null : _test),
        const SizedBox(width: 7),
        NimboButton('编辑',
            kind: NimboButtonKind.secondary, height: 28, onPressed: widget.onEdit),
        const SizedBox(width: 7),
        NimboButton('打开',
            kind: NimboButtonKind.primary, height: 28, onPressed: widget.onOpen),
        const SizedBox(width: 3),
        Container(width: 1, height: 14, color: NimboColors.line),
        const SizedBox(width: 3),
        NimboButton('删除',
            kind: NimboButtonKind.danger, height: 28, onPressed: widget.onDelete),
      ],
    );
  }
}
