import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../core/models.dart';
import '../state/app_state.dart';
import '../ui/kit.dart';

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
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('挂载管理', style: NimboText.display),
                  SizedBox(height: 4),
                  Text('协议差异集中在这里，文件页保持同构',
                      style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: NimboColors.ink3)),
                ],
              ),
              const Spacer(),
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

class _MountCard extends StatelessWidget {
  const _MountCard({
    required this.mount,
    required this.active,
    required this.onOpen,
    required this.onDelete,
  });

  final Mount mount;
  final bool active;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(NimboRadius.panel),
        border: Border.all(color: active ? const Color(0xFFBAE6FD) : NimboColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ProtocolBadge(mount.protocol),
              const SizedBox(width: 8),
              Text(mount.name,
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800)),
              if (active) ...[
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
              const Spacer(),
              if (mount.readOnly)
                const Text('只读',
                    style: TextStyle(
                        fontSize: 9.5, fontWeight: FontWeight.w700, color: NimboColors.warnInk)),
              const SizedBox(width: 10),
              InkWell(
                onTap: onDelete,
                child: const Icon(Icons.delete_outline_rounded, size: 15, color: NimboColors.ink4),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            mount.protocol == MountProtocol.local
                ? mount.rootPath
                : '${mount.host}${mount.port > 0 ? ':${mount.port}' : ''}${mount.protocol == MountProtocol.s3 && mount.bucket.isNotEmpty ? ' / ${mount.bucket}' : ''}',
            style: const TextStyle(
                fontSize: 9.5, fontFamily: 'monospace', color: NimboColors.ink3, height: 1.5),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(
                mount.proxy.enabled ? Icons.link_rounded : Icons.link_off,
                size: 12,
                color: mount.proxy.enabled ? NimboColors.sky700 : NimboColors.ink4,
              ),
              const SizedBox(width: 4),
              Text(
                mount.proxy.enabled ? '经 ${mount.proxy.label}（仅本挂载）' : '直连',
                style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w600,
                    color: mount.proxy.enabled ? NimboColors.sky700 : NimboColors.ink4),
              ),
              const Spacer(),
              NimboButton('打开',
                  kind: NimboButtonKind.secondary, height: 26, onPressed: onOpen),
            ],
          ),
        ],
      ),
    );
  }
}
