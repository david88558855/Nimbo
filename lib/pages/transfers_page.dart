import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../core/format.dart';
import '../core/models.dart';
import '../state/app_state.dart';
import '../ui/kit.dart';

class TransfersPage extends StatelessWidget {
  const TransfersPage({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final running = state.tasks.where((t) => t.status == TransferStatus.running).toList();
    final active = state.tasks.where((t) => t.isActive).toList();
    final finished = state.tasks.where((t) => !t.isActive).toList();
    final speed = state.transfers.totalSpeed;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('传输', style: NimboText.display),
                  const SizedBox(height: 4),
                  Text(
                    '${state.tasks.length} 个任务 · 进行中 ${running.length}'
                    '${state.transfers.queuedCount > 0 ? ' · 排队 ${state.transfers.queuedCount}' : ''}'
                    '${speed > 0 ? ' · ${humanSpeed(speed)}' : ''}',
                    style: const TextStyle(
                        fontSize: 10.5, fontWeight: FontWeight.w600, color: NimboColors.ink3),
                  ),
                ],
              ),
              const Spacer(),
              NimboButton('清理已完成',
                  kind: NimboButtonKind.ghost, onPressed: state.clearFinishedTasks),
            ],
          ),
        ),
        Expanded(
          child: state.tasks.isEmpty
              ? const EmptyBlock(
                  icon: Icons.swap_vert_rounded,
                  title: '还没有传输任务',
                  subtitle: '在文件页上传或下载文件，进度会出现在这里。\n上传与下载可以同时进行，每个任务独占一条连接。',
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                  children: [
                    for (final t in active) ...[
                      _TaskCard(state: state, task: t),
                      const SizedBox(height: 8),
                    ],
                    if (finished.isNotEmpty) ...[
                      if (active.isNotEmpty) const SizedBox(height: 8),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8, top: 2),
                        child: Text('已结束 ${finished.length}',
                            style: const TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.2,
                                color: NimboColors.ink4)),
                      ),
                      for (final t in finished) ...[
                        _TaskCard(state: state, task: t),
                        const SizedBox(height: 8),
                      ],
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.state, required this.task});
  final AppState state;
  final TransferTask task;

  @override
  Widget build(BuildContext context) {
    final failed = task.status == TransferStatus.failed;
    final done = task.status == TransferStatus.done;
    final paused = task.status == TransferStatus.paused;
    final queued = task.status == TransferStatus.queued;
    final color = failed
        ? NimboColors.danger
        : done
            ? NimboColors.ok
            : paused || queued
                ? NimboColors.warn
                : NimboColors.sky600;

    final remain = task.remaining;
    final canResume = (paused || failed) && task.resumable && task.resumeOffset > 0;
    final sub = failed
        ? (task.error ?? '失败')
        : '${humanBytes(task.transferred)} / ${task.total > 0 ? humanBytes(task.total) : '未知大小'}'
            '${task.speed > 0 ? ' · ${humanSpeed(task.speed)}' : ''}'
            '${remain != null ? ' · 剩余 ${_fmtRemain(remain)}' : ''}'
            '${canResume ? ' · 可从 ${humanBytes(task.resumeOffset)} 续传' : ''}';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(NimboRadius.panel),
        border: Border.all(color: NimboColors.line),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: failed ? const Color(0x14F43F5E) : const Color(0x1438BDF8),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  failed
                      ? Icons.error_outline_rounded
                      : done
                          ? Icons.check_rounded
                          : paused
                              ? Icons.pause_rounded
                              : task.dir == TransferDir.upload
                                  ? Icons.upload_rounded
                                  : Icons.download_rounded,
                  size: 15,
                  color: color,
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(task.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                        ),
                        const SizedBox(width: 5),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF0F6FC),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(task.dir.label,
                              style: const TextStyle(
                                  fontSize: 8.5,
                                  fontWeight: FontWeight.w800,
                                  color: NimboColors.ink3)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${task.mountName} · ${task.dir == TransferDir.upload ? task.localPath : task.remotePath}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 9.5, color: NimboColors.ink4),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                task.status.label,
                style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: color),
              ),
              const SizedBox(width: 4),
              _action(Icons.pause_rounded, '暂停',
                  task.status == TransferStatus.running || queued
                      ? () => state.transfers.toggle(task)
                      : null),
              _action(Icons.play_arrow_rounded, '继续',
                  paused || failed ? () => state.transfers.resume(task) : null),
              _action(Icons.close_rounded, '取消', () => state.transfers.cancel(task)),
            ],
          ),
          const SizedBox(height: 9),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: done ? 1 : task.progress,
              minHeight: 4,
              backgroundColor: NimboColors.line2,
              color: color,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w600,
                      color: failed ? NimboColors.dangerInk : NimboColors.ink3),
                ),
              ),
              Text('${(task.progress * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(
                      fontSize: 9.5, fontWeight: FontWeight.w700, color: NimboColors.ink3)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _action(IconData icon, String tip, VoidCallback? onTap) => Tooltip(
        message: tip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.all(5),
            child: Icon(icon,
                size: 15, color: onTap == null ? const Color(0xFFCBD8E4) : NimboColors.ink3),
          ),
        ),
      );

  static String _fmtRemain(Duration d) {
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
    if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds % 60}s';
    return '${d.inSeconds}s';
  }
}
