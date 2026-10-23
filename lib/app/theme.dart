import 'package:flutter/material.dart';

/// 设计 token —— 与 design/index.html 的 CSS 变量一一对应。
/// 单一浅色主题：这里不再保留第二套调色板。
class NimboColors {
  const NimboColors._();

  // 品牌
  static const sky = Color(0xFF38BDF8);
  static const sky600 = Color(0xFF0EA5E9);
  static const sky700 = Color(0xFF0284C7);
  static const teal = Color(0xFF2DD4BF);
  static const deep = Color(0xFF0E3A46);

  // 中性
  static const bg = Color(0xFFEDF2F8);
  static const card = Color(0xFFFFFFFF);
  static const surface = Color(0xFFF8FAFD);
  static const surfaceAlt = Color(0xFFFCFDFF);
  static const line = Color(0xFFE3EBF3);
  static const line2 = Color(0xFFEEF3F8);
  static const hair = Color(0xFFF0F4F9);
  static const ink = Color(0xFF0D1B2A);
  static const ink2 = Color(0xFF41546A);
  static const ink3 = Color(0xFF7C8FA3);
  static const ink4 = Color(0xFF9AABBC);

  // 语义
  static const ok = Color(0xFF22C55E);
  static const okInk = Color(0xFF137A4B);
  static const warn = Color(0xFFF59E0B);
  static const warnInk = Color(0xFFA9700A);
  static const danger = Color(0xFFF43F5E);
  static const dangerInk = Color(0xFFB3203B);
  static const navOnBg = Color(0xFFE6F6FE);
  static const navOn = Color(0xFF075E7E);

  // 文件类型
  static const tFolder = Color(0xFF0A93C4);
  static const tVideo = Color(0xFF7C5CFC);
  static const tImage = Color(0xFFE8476F);
  static const tDoc = Color(0xFFD98A06);
  static const tAudio = Color(0xFF0DA98F);
  static const tArchive = Color(0xFF63788E);
  static const tCode = Color(0xFF0EA5E9);

  static const gradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF38BDF8), Color(0xFF20C6C8)],
  );

  // 协议色（徽标底 + 文字，始终与文字同现）
  static const pFtp = Color(0xFFA9700A);
  static const pFtpBg = Color(0x21D98A06);
  static const pSftp = Color(0xFF137A4B);
  static const pSftpBg = Color(0x2122C55E);
  static const pS3 = Color(0xFF5B41D6);
  static const pS3Bg = Color(0x247C5CFC);
  static const pDav = Color(0xFF0A8068);
  static const pDavBg = Color(0x210DA98F);
  static const pLocal = Color(0xFF4A6076);
  static const pLocalBg = Color(0x2963788E);
}

class NimboText {
  const NimboText._();

  static const display = TextStyle(fontSize: 26, height: 1.1, letterSpacing: -1.0, fontWeight: FontWeight.w800, color: NimboColors.ink);
  static const title = TextStyle(fontSize: 15, height: 1.3, letterSpacing: -0.3, fontWeight: FontWeight.w800, color: NimboColors.ink);
  static const body = TextStyle(fontSize: 12.5, height: 1.35, fontWeight: FontWeight.w500, color: NimboColors.ink);
  static const bodyStrong = TextStyle(fontSize: 12.5, height: 1.35, fontWeight: FontWeight.w600, color: NimboColors.ink);
  static const caption = TextStyle(fontSize: 10, height: 1.4, fontWeight: FontWeight.w600, color: NimboColors.ink3);
  static const micro = TextStyle(fontSize: 9, height: 1.4, letterSpacing: 1.0, fontWeight: FontWeight.w800, color: NimboColors.ink4);
  static const mono = TextStyle(fontSize: 10, height: 1.5, letterSpacing: 0.2, fontFamily: 'monospace', color: NimboColors.ink3);
}

class NimboRadius {
  const NimboRadius._();
  static const card = 20.0;
  static const panel = 14.0;
  static const field = 9.0;
}

ThemeData buildNimboTheme() {
  final scheme = const ColorScheme.light(
    primary: NimboColors.sky600,
    onPrimary: Colors.white,
    secondary: NimboColors.teal,
    surface: NimboColors.card,
    onSurface: NimboColors.ink,
    error: NimboColors.danger,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: NimboColors.bg,
    canvasColor: NimboColors.bg,
    dividerColor: NimboColors.line,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    appBarTheme: const AppBarTheme(
      backgroundColor: NimboColors.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      toolbarHeight: 52,
      titleTextStyle: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: NimboColors.ink),
      iconTheme: IconThemeData(color: NimboColors.ink2, size: 20),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: NimboColors.ink, borderRadius: BorderRadius.circular(7)),
      textStyle: const TextStyle(fontSize: 11, color: Colors.white),
    ),
  );
}
