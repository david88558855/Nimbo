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
    final running = state.tasks.where((t) => t.status == TransferStatus.running).length;
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
                  Text('${state.tasks.length} 个任务 · $running 进行中',
                      style: const TextStyle(
                          fontSize: 10.5, fontWeight: FontWeight.w600, color: NimboColors.ink3)),
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
                  subtitle: '在文件页选择文件下载，进度会出现在这里。',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                  itemCount: state.tasks.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) => _TaskCard(task: state.tasks[i]),
                ),
        ),
      ],
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.task});
  final TransferTask task;

  @override
  Widget build(BuildContext context) {
    final failed = task.status == TransferStatus.failed;
    final done = task.status == TransferStatus.done;
    final color = failed
        ? NimboColors.danger
        : done
            ? NimboColors.ok
            : NimboColors.sky600;
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
                    Text(task.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text('${task.mountName} · ${task.remotePath}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 9.5, color: NimboColors.ink4)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                task.status.label,
                style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: color),
              ),
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
              Text(
                failed
                    ? (task.error ?? '失败')
                    : '${humanBytes(task.transferred)} / ${task.total > 0 ? humanBytes(task.total) : '未知大小'}',
                style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w600,
                    color: failed ? NimboColors.dangerInk : NimboColors.ink3),
              ),
              const Spacer(),
              Text('${(task.progress * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(
                      fontSize: 9.5, fontWeight: FontWeight.w700, color: NimboColors.ink3)),
            ],
          ),
        ],
      ),
    );
  }
}
