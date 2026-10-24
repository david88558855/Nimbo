import 'package:flutter/material.dart';

import 'models.dart';

String humanBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  final s = v >= 100 || i == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  return '$s ${units[i]}';
}

String humanSpeed(double bytesPerSecond) {
  if (bytesPerSecond <= 0) return '—';
  return '${humanBytes(bytesPerSecond.round())}/s';
}

String formatDate(DateTime? t) {
  if (t == null) return '—';
  final l = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
}

String formatShortDate(DateTime? t) {
  if (t == null) return '—';
  final l = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
}

class EntryVisual {
  const EntryVisual(this.icon, this.color, this.background);
  final IconData icon;
  final Color color;
  final Color background;
}

EntryVisual visualFor(RemoteEntry entry) {
  if (entry.isDir) {
    return const EntryVisual(Icons.folder_rounded, Color(0xFF0A93C4), Color(0x1C0A93C4));
  }
  switch (entry.extension) {
    case 'mp4':
    case 'mkv':
    case 'mov':
    case 'avi':
    case 'webm':
      return const EntryVisual(Icons.movie_outlined, Color(0xFF7C5CFC), Color(0x1C7C5CFC));
    case 'png':
    case 'jpg':
    case 'jpeg':
    case 'gif':
    case 'webp':
    case 'heic':
    case 'svg':
      return const EntryVisual(Icons.image_outlined, Color(0xFFE8476F), Color(0x1CE8476F));
    case 'pdf':
    case 'doc':
    case 'docx':
    case 'xls':
    case 'xlsx':
    case 'ppt':
    case 'pptx':
    case 'txt':
    case 'md':
      return const EntryVisual(Icons.description_outlined, Color(0xFFD98A06), Color(0x21D98A06));
    case 'mp3':
    case 'flac':
    case 'wav':
    case 'm4a':
    case 'aac':
      return const EntryVisual(Icons.audiotrack_outlined, Color(0xFF0DA98F), Color(0x1F0DA98F));
    case 'zip':
    case 'rar':
    case '7z':
    case 'tar':
    case 'gz':
    case 'zst':
      return const EntryVisual(Icons.folder_zip_outlined, Color(0xFF63788E), Color(0x2163788E));
    case 'dart':
    case 'js':
    case 'ts':
    case 'json':
    case 'yml':
    case 'yaml':
    case 'py':
    case 'go':
    case 'rs':
      return const EntryVisual(Icons.code, Color(0xFF0EA5E9), Color(0x1F0EA5E9));
    default:
      return const EntryVisual(Icons.insert_drive_file_outlined, Color(0xFF63788E), Color(0x2163788E));
  }
}

/// 路径拼接：保持单个前导斜杠，去掉重复分隔符。
String joinPath(String base, String name) {
  final b = base.isEmpty ? '/' : base;
  if (b == '/') return '/$name';
  return '${b.replaceAll(RegExp(r'/+$'), '')}/$name';
}

String parentPath(String path) {
  if (path == '/' || path.isEmpty) return '/';
  final trimmed = path.replaceAll(RegExp(r'/+$'), '');
  final i = trimmed.lastIndexOf('/');
  if (i <= 0) return '/';
  return trimmed.substring(0, i);
}

List<String> splitPath(String path) =>
    path.split('/').where((s) => s.isNotEmpty).toList();

String normalizePath(String path) {
  var p = path.trim();
  if (p.isEmpty) return '/';
  if (!p.startsWith('/')) p = '/$p';
  p = p.replaceAll(RegExp(r'/+'), '/');
  if (p.length > 1 && p.endsWith('/')) p = p.substring(0, p.length - 1);
  return p;
}

/// 本地落盘名：去掉 Windows 非法字符，避免下载失败才发现。
String sanitizeName(String name) {
  var s = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  if (s.isEmpty) s = 'unnamed';
  if (s.length > 180) s = s.substring(0, 180);
  return s;
}
