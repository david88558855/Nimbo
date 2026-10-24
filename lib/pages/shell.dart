import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/theme.dart';
import '../core/models.dart';
import '../core/version.dart';
import '../state/app_state.dart';
import '../ui/kit.dart';
import 'add_mount_page.dart';
import 'files_page.dart';
import 'mounts_page.dart';
import 'settings_page.dart';
import 'transfers_page.dart';

class NimboShell extends StatefulWidget {
  const NimboShell({super.key, required this.state});
  final AppState state;

  @override
  State<NimboShell> createState() => _NimboShellState();
}

class _NimboShellState extends State<NimboShell> {
  int _index = 0;

  AppState get state => widget.state;

  Future<void> _openAddMount() async {
    final created = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AddMountDialog(state: state),
    );
    if (created == true && mounted) setState(() => _index = 0);
  }

  void _go(int index) => setState(() => _index = index);

  /// 系统返回键：逐级回退；到「全部挂载」根后必须连按两次才退出应用。
  bool get _canPop => false;

  DateTime? _lastBackAt;

  void _onPop(bool didPop, Object? result) {
    if (didPop) return;
    if (_index != 0) {
      _go(0);
      return;
    }
    if (state.selectionMode) {
      state.exitSelection();
      return;
    }
    if (!state.browseAll) {
      // 目录 → 上级目录；挂载根 → 全部挂载（AppState.up 内部处理）
      state.up();
      return;
    }
    // 已在「全部挂载」根：第一次只提示，2 秒内再按一次才真正退出
    final now = DateTime.now();
    final last = _lastBackAt;
    _lastBackAt = now;
    if (last != null && now.difference(last) < const Duration(seconds: 2)) {
      SystemNavigator.pop();
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('再按一次返回键退出 Nimbo'),
      duration: Duration(seconds: 2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final pages = <Widget>[
      FilesPage(state: state, onAddMount: _openAddMount, onOpenMounts: () => _go(2)),
      TransfersPage(state: state),
      MountsPage(state: state, onAddMount: _openAddMount, onOpenFiles: () => _go(0)),
      SettingsPage(state: state),
    ];

    if (wide) {
      return PopScope(
        canPop: _canPop,
        onPopInvokedWithResult: _onPop,
        child: Scaffold(
          backgroundColor: NimboColors.bg,
          body: Row(
            children: [
              _Rail(
                state: state,
                index: _index,
                onSelect: _go,
                onAddMount: _openAddMount,
              ),
              const VerticalDivider(width: 1, thickness: 1, color: NimboColors.line),
              Expanded(child: pages[_index]),
            ],
          ),
        ),
      );
    }

    return PopScope(
      canPop: _canPop,
      onPopInvokedWithResult: _onPop,
      child: Scaffold(
        backgroundColor: NimboColors.bg,
        body: SafeArea(child: pages[_index]),
        bottomNavigationBar: Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: NimboColors.line)),
          ),
          child: NavigationBar(
            // 底部 Tab 的高度要跟着字号走，否则放大的标签会被裁。
            height: uiSize(62),
            selectedIndex: _index,
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            indicatorColor: NimboColors.navOnBg,
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            onDestinationSelected: _go,
            destinations: const [
              NavigationDestination(
                  icon: Icon(Icons.folder_outlined, size: 20),
                  selectedIcon: Icon(Icons.folder_rounded, size: 20, color: NimboColors.navOn),
                  label: '文件'),
              NavigationDestination(
                  icon: Icon(Icons.swap_vert_rounded, size: 20),
                  selectedIcon: Icon(Icons.swap_vert_rounded, size: 20, color: NimboColors.navOn),
                  label: '传输'),
              NavigationDestination(
                  icon: Icon(Icons.dns_outlined, size: 20),
                  selectedIcon: Icon(Icons.dns_rounded, size: 20, color: NimboColors.navOn),
                  label: '挂载'),
              NavigationDestination(
                  icon: Icon(Icons.tune_rounded, size: 20),
                  selectedIcon: Icon(Icons.tune_rounded, size: 20, color: NimboColors.navOn),
                  label: '设置'),
            ],
          ),
        ),
      ),
    );
  }
}

class _Rail extends StatelessWidget {
  const _Rail({
    required this.state,
    required this.index,
    required this.onSelect,
    required this.onAddMount,
  });

  final AppState state;
  final int index;
  final ValueChanged<int> onSelect;
  final VoidCallback onAddMount;

  @override
  Widget build(BuildContext context) {
    final active = state.activeMount;
    return Container(
      width: 236,
      color: NimboColors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
            child: Row(
              children: [
                Container(
                  width: uiSize(28),
                  height: uiSize(28),
                  decoration: BoxDecoration(
                    gradient: NimboColors.gradient,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(Icons.cloud_outlined, size: uiSize(17), color: Colors.white),
                ),
                const SizedBox(width: 9),
                const Text('Nimbo',
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: NimboColors.ink)),
                const SizedBox(width: 6),
                const Text(kAppVersion,
                    style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: NimboColors.ink4)),
              ],
            ),
          ),
          // Windows 桌面端不显示这个「未选择挂载 / 点击选择」切换器：
          // 侧栏下方就是完整挂载列表（点一下即切换），「挂载管理」页也能添加挂载，
          // 这里再放一个下拉是重复入口。其它平台（宽屏平板）保持原样。
          if (defaultTargetPlatform != TargetPlatform.windows) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 9),
              child: _MountSwitcher(state: state, onAddMount: onAddMount),
            ),
            const SizedBox(height: 10),
          ],
          _NavItem(
            icon: Icons.folder_rounded,
            label: '全部文件',
            selected: index == 0,
            onTap: () {
              state.showAll();
              onSelect(0);
            },
          ),
          _NavItem(
            icon: Icons.swap_vert_rounded,
            label: '传输',
            selected: index == 1,
            count: state.tasks.where((t) => t.status == TransferStatus.running).length,
            onTap: () => onSelect(1),
          ),
          _NavItem(
            icon: Icons.dns_rounded,
            label: '挂载管理',
            selected: index == 2,
            count: state.mounts.length,
            onTap: () => onSelect(2),
          ),
          _NavItem(
            icon: Icons.tune_rounded,
            label: '设置',
            selected: index == 3,
            onTap: () => onSelect(3),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 16, 18, 8),
            child: Text('我的挂载',
                style: TextStyle(
                    fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 1.2, color: NimboColors.ink4)),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 9),
              children: [
                for (final m in state.mounts)
                  _MountRow(
                    mount: m,
                    selected: m.id == active?.id,
                    onTap: () {
                      state.open(m);
                      onSelect(0);
                    },
                  ),
              ],
            ),
          ),
          if (active != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 14),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: NimboColors.line),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.lan_outlined, size: 12, color: NimboColors.ink3),
                        const SizedBox(width: 5),
                        Text('${active.protocol.label} 挂载',
                            style: const TextStyle(
                                fontSize: 9.5, fontWeight: FontWeight.w800, color: NimboColors.ink3)),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      active.proxy.enabled ? '代理 ${active.proxy.label}' : '直连 · 无代理',
                      style: const TextStyle(fontSize: 9.5, height: 1.5, color: NimboColors.ink3),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MountSwitcher extends StatelessWidget {
  const _MountSwitcher({required this.state, required this.onAddMount});
  final AppState state;
  final VoidCallback onAddMount;

  @override
  Widget build(BuildContext context) {
    final active = state.activeMount;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: NimboColors.line),
      ),
      child: PopupMenuButton<String>(
        tooltip: '切换挂载',
        onSelected: (id) {
          if (id == '__add__') {
            onAddMount();
            return;
          }
          for (final m in state.mounts) {
            if (m.id == id) {
              state.open(m);
              return;
            }
          }
        },
        itemBuilder: (_) => [
          for (final m in state.mounts)
            PopupMenuItem<String>(
              value: m.id,
              child: Row(
                children: [
                  ProtocolBadge(m.protocol, compact: true),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(m.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
          const PopupMenuDivider(),
          const PopupMenuItem<String>(
            value: '__add__',
            child: Row(
              children: [
                Icon(Icons.add_rounded, size: 15, color: NimboColors.sky600),
                SizedBox(width: 7),
                Text('添加挂载', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ],
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Container(
                width: uiSize(30),
                height: uiSize(30),
                decoration: BoxDecoration(
                  gradient: NimboColors.gradient,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Center(
                  child: Text(
                    (active?.protocol.label ?? 'N').substring(0, 1),
                    style: const TextStyle(
                        fontSize: 10, fontWeight: FontWeight.w800, color: Colors.white),
                  ),
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(active?.name ?? '未选择挂载',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 11.5, fontWeight: FontWeight.w800, color: NimboColors.ink)),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        const StatusDot(),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            active == null
                                ? '点击选择'
                                : '${active.protocol.label} · ${active.subtitle}',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 9, fontWeight: FontWeight.w600, color: NimboColors.ink3),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const Icon(Icons.unfold_more_rounded, size: 14, color: NimboColors.ink4),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final color = selected ? NimboColors.navOn : const Color(0xFF50647A);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 1),
      child: Material(
        color: selected ? NimboColors.navOnBg : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: onTap,
          child: Container(
            height: uiSize(34),
            padding: const EdgeInsets.symmetric(horizontal: 9),
            child: Row(
              children: [
                Icon(icon, size: uiSize(15), color: color),
                const SizedBox(width: 9),
                Text(label,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                        color: color)),
                const Spacer(),
                if (count != null && count! > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: selected ? Colors.white : const Color(0xFFEDF3F9),
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Text('$count',
                        style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            color: selected ? NimboColors.sky700 : NimboColors.ink3)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MountRow extends StatelessWidget {
  const _MountRow({required this.mount, required this.selected, required this.onTap});
  final Mount mount;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected ? Colors.white : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
            child: Row(
              children: [
                const StatusDot(),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    mount.name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                      color: selected ? NimboColors.ink : NimboColors.ink2,
                    ),
                  ),
                ),
                ProtocolBadge(mount.protocol, compact: true),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
