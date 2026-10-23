import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../state/app_state.dart';
import '../ui/kit.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 24),
      children: [
        const Text('设置', style: NimboText.display),
        const SizedBox(height: 4),
        const Text('单一浅色主题：没有外观开关，减少两套配色的维护与测试成本',
            style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: NimboColors.ink3)),
        const SizedBox(height: 16),
        SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _Label('数据'),
              const SizedBox(height: 10),
              _row('数据目录', state.dataDirPath.isEmpty ? '—' : state.dataDirPath, mono: true),
              _row('存储方式', state.portable ? '便携（随程序目录）' : '系统目录'),
              _row('配置文件', 'userdata/prefs.json（不含任何密码）'),
            ],
          ),
        ),
        const SizedBox(height: 10),
        SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _Label('传输'),
              const SizedBox(height: 10),
              _row('下载目录', 'Windows：用户下载目录下的 Nimbo；Android：应用文档目录'),
              const SizedBox(height: 6),
              Row(
                children: [
                  const SizedBox(
                    width: 92,
                    child: Text('并发任务',
                        style: TextStyle(
                            fontSize: 10.5, fontWeight: FontWeight.w600, color: NimboColors.ink3)),
                  ),
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFFF3F8FC),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: NimboColors.line),
                    ),
                    padding: const EdgeInsets.all(2),
                    child: Row(
                      children: [
                        for (final n in [1, 2, 3, 4])
                          InkWell(
                            onTap: () => state.updateSettings((s) => s.maxConcurrent = n),
                            borderRadius: BorderRadius.circular(6),
                            child: Container(
                              width: 30,
                              height: 24,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: state.settings.maxConcurrent == n
                                    ? Colors.white
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(6),
                                boxShadow: state.settings.maxConcurrent == n
                                    ? const [
                                        BoxShadow(
                                            color: Color(0x140D1B2A),
                                            blurRadius: 4,
                                            offset: Offset(0, 1))
                                      ]
                                    : null,
                              ),
                              child: Text('$n',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                    color: state.settings.maxConcurrent == n
                                        ? NimboColors.sky700
                                        : NimboColors.ink3,
                                  )),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text('每个任务独占一条连接；FTP 建议 1–2',
                        style: TextStyle(
                            fontSize: 9.5, fontWeight: FontWeight.w600, color: NimboColors.ink4)),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              _row('断点续传', '暂停后重新开始（S3 分片会 Abort 清理，不留碎片）'),
            ],
          ),
        ),
        const SizedBox(height: 10),
        SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _Label('安全'),
              const SizedBox(height: 10),
              _row('凭据存储', '系统安全存储（Windows Credential Manager / Android Keystore）'),
              _row('代理', '按挂载一对一配置，无全局代理，不读系统代理'),
              _row('明文 FTP', '仅建议在可信内网使用'),
            ],
          ),
        ),
        const SizedBox(height: 10),
        SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _Label('关于'),
              const SizedBox(height: 10),
              _row('版本', '0.2.0 (P1 传输闭环)'),
              _row('协议', 'FTP · SFTP · S3 兼容 · WebDAV · 本地与映射盘'),
              _row('代理', 'HTTP CONNECT / SOCKS5，五个协议全部接入（含 SFTP）'),
              _row('构建', 'GitHub Actions 云端编译，无本地构建产物'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(String label, String value, {bool mono = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 92,
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 10.5, fontWeight: FontWeight.w600, color: NimboColors.ink3)),
            ),
            Expanded(
              child: Text(value,
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.6,
                    fontWeight: FontWeight.w600,
                    color: NimboColors.ink2,
                    fontFamily: mono ? 'monospace' : null,
                  )),
            ),
          ],
        ),
      );
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(
          fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 1.2, color: NimboColors.ink4));
}
