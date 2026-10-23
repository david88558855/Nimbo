import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../core/format.dart';
import '../core/models.dart';
import '../state/app_state.dart';
import '../ui/kit.dart';

/// 可直接在应用内预览的扩展名。其余类型提示「下载后查看」。
const _imageExt = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'ico'};
const _textExt = {
  'txt', 'md', 'json', 'yaml', 'yml', 'log', 'csv', 'xml', 'ini', 'conf', 'toml',
  'dart', 'js', 'ts', 'jsx', 'tsx', 'py', 'go', 'rs', 'java', 'kt', 'c', 'h',
  'cpp', 'cs', 'php', 'rb', 'sh', 'bat', 'ps1', 'html', 'css', 'scss', 'sql',
};

/// 图片 24 MB、文本 1 MB —— 超过就提示下载，避免把整份大文件读进内存。
const _imageLimit = 24 * 1024 * 1024;
const _textLimit = 1024 * 1024;

bool canPreviewEntry(RemoteEntry entry) =>
    !entry.isDir && (_imageExt.contains(entry.extension) || _textExt.contains(entry.extension));

Future<void> showPreview(BuildContext context, AppState state, RemoteEntry entry) {
  return showDialog<void>(
    context: context,
    barrierColor: const Color(0xCC0D1B2A),
    builder: (_) => _PreviewDialog(state: state, entry: entry),
  );
}

class _PreviewDialog extends StatefulWidget {
  const _PreviewDialog({required this.state, required this.entry});

  final AppState state;
  final RemoteEntry entry;

  @override
  State<_PreviewDialog> createState() => _PreviewDialogState();
}

class _PreviewDialogState extends State<_PreviewDialog> {
  late Future<Uint8List> _future;

  RemoteEntry get entry => widget.entry;
  bool get _isImage => _imageExt.contains(entry.extension);

  @override
  void initState() {
    super.initState();
    _future = widget.state.readEntry(entry);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final width = size.width < 820 ? size.width - 40 : 780.0;
    final height = size.height < 640 ? size.height - 60 : 600.0;
    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.all(20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(NimboRadius.panel)),
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          children: [
            _titleBar(),
            const Divider(height: 1, color: NimboColors.line),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _titleBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
      child: Row(
        children: [
          EntryTile(entry: entry, size: 26),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w800, color: NimboColors.ink)),
                const SizedBox(height: 1),
                Text(
                  '${entry.extension.isEmpty ? '文件' : entry.extension.toUpperCase()} · '
                  '${humanBytes(entry.size)}',
                  style: const TextStyle(
                      fontSize: 9.5, fontWeight: FontWeight.w600, color: NimboColors.ink4),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '关闭',
            visualDensity: VisualDensity.compact,
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded, size: 18, color: NimboColors.ink3),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    final limit = _isImage ? _imageLimit : _textLimit;
    if (entry.size > limit) {
      return EmptyBlock(
        icon: Icons.data_usage_rounded,
        title: '文件太大，无法预览',
        subtitle: '${humanBytes(entry.size)} 超过 ${humanBytes(limit)} 的预览上限，请下载后查看。',
      );
    }
    return FutureBuilder<Uint8List>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2, color: NimboColors.sky600),
            ),
          );
        }
        if (snap.hasError) {
          return EmptyBlock(
            icon: Icons.error_outline_rounded,
            danger: true,
            title: '读取失败',
            subtitle: '${snap.error}',
            actionLabel: '重试',
            onAction: () => setState(() => _future = widget.state.readEntry(entry)),
          );
        }
        final bytes = snap.data ?? Uint8List(0);
        if (bytes.isEmpty) {
          return const EmptyBlock(icon: Icons.insert_drive_file_outlined, title: '空文件');
        }
        return _isImage ? _image(bytes) : _text(bytes);
      },
    );
  }

  Widget _image(Uint8List bytes) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: const Color(0xFFF7FAFD),
      child: InteractiveViewer(
        minScale: 0.5,
        maxScale: 6,
        child: Center(child: Image.memory(bytes, fit: BoxFit.contain)),
      ),
    );
  }

  Widget _text(Uint8List bytes) {
    String content;
    try {
      content = utf8.decode(bytes);
    } catch (_) {
      content = utf8.decode(bytes, allowMalformed: true);
    }
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: Colors.white,
      child: Scrollbar(
        thumbVisibility: true,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: SelectableText(
            content,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              height: 1.55,
              color: NimboColors.ink,
            ),
          ),
        ),
      ),
    );
  }
}
