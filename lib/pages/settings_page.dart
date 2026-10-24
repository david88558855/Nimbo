import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../core/version.dart';
import '../drivers/errors.dart';
import '../state/app_state.dart';
import '../ui/kit.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.state});
  final AppState state;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _uploadLimit;
  late final TextEditingController _downloadLimit;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _uploadLimit = TextEditingController(text: _kbpsText(state.settings.uploadLimitKbps));
    _downloadLimit =
        TextEditingController(text: _kbpsText(state.settings.downloadLimitKbps));
  }

  @override
  void dispose() {
    _uploadLimit.dispose();
    _downloadLimit.dispose();
    super.dispose();
  }

  static String _kbpsText(int v) => v <= 0 ? '' : '$v';

  /// 默认下载目录的**描述**（真实路径由传输层算，且不可用时会自动回落）。
  String get _defaultDownloadHint => Platform.isWindows ? '下载/Nimbo' : '应用文档目录/Nimbo';

  /// 选下载目录：只存路径，真正建目录/校验可写在传输层做
  /// （换机器、删目录、目录变文件都能自动回落到默认位置）。
  Future<void> _pickDownloadDir() async {
    try {
      final picked = await FilePicker.platform.getDirectoryPath(dialogTitle: '选择下载目录');
      if (picked == null || picked.trim().isEmpty) return;
      if (!mounted) return;
      await state.updateSettings((s) => s.downloadDir = picked.trim());
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(describeError(e))),
      );
    }
  }

  /// 输入框留空或填 0 都表示「不限」。
  void _applyLimit({required bool upload}) {
    final controller = upload ? _uploadLimit : _downloadLimit;
    final raw = controller.text.trim();
    final kbps = int.tryParse(raw) ?? 0;
    final value = kbps < 0 ? 0 : kbps;
    controller.text = _kbpsText(value);
    state.updateSettings((s) {
      if (upload) {
        s.uploadLimitKbps = value;
      } else {
        s.downloadLimitKbps = value;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = state.settings;
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 24),
      children: [
        const Text('设置', style: NimboText.display),
        const SizedBox(height: 4),
        const Text('单一浅色主题：没有外观开关，减少两套配色的维护与测试成本',
            style: TextStyle(
                fontSize: 10.5, fontWeight: FontWeight.w600, color: NimboColors.ink3)),
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
              // 下载目录现在是可配置项，具体行在下方（这里不再放只读说明）。
              Row(
                children: [
                  const SizedBox(
                    width: 92,
                    child: Text('并发任务',
                        style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: NimboColors.ink3)),
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
                            // 标记「用户自己选过」：老配置里那个 2 是旧默认值写进去的，
                            // 不标记的话改默认值对老用户永远不生效（见 AppSettings 注释）。
                            onTap: () => state.updateSettings((s) {
                              s.maxConcurrent = n;
                              s.maxConcurrentPinned = true;
                            }),
                            borderRadius: BorderRadius.circular(6),
                            child: Container(
                              width: uiSize(30),
                              height: uiSize(24),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: s.maxConcurrent == n
                                    ? Colors.white
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(6),
                                boxShadow: s.maxConcurrent == n
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
                                    color: s.maxConcurrent == n
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
                            fontSize: 9.5,
                            fontWeight: FontWeight.w600,
                            color: NimboColors.ink4)),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(
                    width: 92,
                    child: Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text('下载目录',
                          style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: NimboColors.ink3)),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.downloadDir.isEmpty
                              ? '默认：$_defaultDownloadHint'
                              : s.downloadDir,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: NimboColors.ink2),
                        ),
                        const SizedBox(height: 6),
                        // Wrap：窄屏 + 放大字号时按钮自动折行，不会溢出。
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            NimboButton('选择目录…',
                                icon: Icons.folder_open_rounded,
                                height: 26,
                                onPressed: _pickDownloadDir),
                            if (s.downloadDir.isNotEmpty)
                              NimboButton('恢复默认',
                                  kind: NimboButtonKind.ghost,
                                  height: 26,
                                  onPressed: () =>
                                      state.updateSettings((x) => x.downloadDir = '')),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(
                    width: 92,
                    child: Padding(
                      padding: EdgeInsets.only(top: 10),
                      child: Text('限速',
                          style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: NimboColors.ink3)),
                    ),
                  ),
                  // 窄屏（手机）放不下两个输入框 + 说明，用 Wrap 自动折行，
                  // 否则 92 + 122 + 10 + 122 + 说明 会直接溢出。
                  Expanded(
                    child: Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _limitField(_uploadLimit, '上传 KB/s', upload: true),
                        _limitField(_downloadLimit, '下载 KB/s', upload: false),
                        const SizedBox(
                          width: 186,
                          child: Text('留空或 0 = 不限速；按全部任务合计',
                              style: TextStyle(
                                  fontSize: 9.5,
                                  height: 1.5,
                                  fontWeight: FontWeight.w600,
                                  color: NimboColors.ink4)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              _row('断点续传', '暂停后重新开始（S3 分片会记录已完成分片，接着传）'),
            ],
          ),
        ),
        const SizedBox(height: 10),
        SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _Label('列表与操作'),
              const SizedBox(height: 6),
              _SwitchRow(
                label: '隐藏以「.」开头的文件',
                value: s.hideHiddenFiles,
                onChanged: (v) => state.updateSettings((x) => x.hideHiddenFiles = v),
              ),
              _SwitchRow(
                label: '删除前二次确认',
                value: s.confirmDelete,
                onChanged: (v) => state.updateSettings((x) => x.confirmDelete = v),
              ),
            ],
          ),
        ),
        if (Platform.isWindows) ...[
          const SizedBox(height: 10),
          SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _Label('桌面'),
                const SizedBox(height: 6),
                _SwitchRow(
                  label: '关闭窗口时收进托盘',
                  hint: '关掉后点 × 直接退出；托盘图标始终可用（双击显示）',
                  value: s.closeToTray,
                  onChanged: (v) => state.updateSettings((x) => x.closeToTray = v),
                ),
                const Divider(height: 18, color: Color(0xFFF0F4F9)),
                _row('单实例', '重复启动只唤起已有窗口，不会出现第二个进程'),
                _row('托盘', '单击无响应；双击或右键菜单「显示主窗口」唤回；右键可退出'),
              ],
            ),
          ),
        ],
        const SizedBox(height: 10),
        SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _Label('安全'),
              const SizedBox(height: 10),
              _row('凭据存储', '系统安全存储（Windows Credential Manager / Android Keystore）'),
              _row('便携备份', 'Windows 额外写 userdata/credentials.dat（可逆混淆，不是加密）'),
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
              _row('版本', kAppVersionLabel),
              _row('协议', 'FTP（含匿名）· SFTP · S3 兼容 · WebDAV · 本地与映射盘'),
              _row('代理', 'HTTP CONNECT / SOCKS5，五个协议全部接入（含 SFTP）'),
              _row('构建', 'GitHub Actions 云端编译，无本地构建产物'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _limitField(TextEditingController controller, String hint,
      {required bool upload}) {
    return SizedBox(
      width: 122,
      child: TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        decoration: nimboInput(hint: hint),
        onSubmitted: (_) => _applyLimit(upload: upload),
        onEditingComplete: () => _applyLimit(upload: upload),
        onTapOutside: (_) {
          FocusManager.instance.primaryFocus?.unfocus();
          _applyLimit(upload: upload);
        },
      ),
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

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.hint,
  });

  final String label;
  final String? hint;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(
                      fontSize: 11.5, fontWeight: FontWeight.w700, color: NimboColors.ink)),
              if (hint != null) ...[
                const SizedBox(height: 2),
                Text(hint!,
                    style: const TextStyle(
                        fontSize: 9.5, height: 1.5, color: NimboColors.ink4)),
              ],
            ],
          ),
        ),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(
          fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 1.2, color: NimboColors.ink4));
}
