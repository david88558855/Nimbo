import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../core/models.dart';
import '../drivers/errors.dart';
import '../drivers/factory.dart';
import '../state/app_state.dart';
import '../ui/kit.dart';

class AddMountDialog extends StatefulWidget {
  const AddMountDialog({super.key, required this.state, this.existing});

  final AppState state;

  /// 传入已保存的挂载即为「编辑」模式：字段预填，密码留空表示不修改。
  final Mount? existing;

  @override
  State<AddMountDialog> createState() => _AddMountDialogState();
}

class _AddMountDialogState extends State<AddMountDialog> {
  MountProtocol _protocol = MountProtocol.webdav;
  final _name = TextEditingController(text: '新挂载');
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();
  final _rootPath = TextEditingController(text: '/');
  final _bucket = TextEditingController();
  final _region = TextEditingController();
  bool _pathStyle = true;
  bool _readOnly = false;
  bool _anonymous = false;

  bool _proxyEnabled = false;
  ProxyType _proxyType = ProxyType.http;
  final _proxyHost = TextEditingController(text: '127.0.0.1');
  final _proxyPort = TextEditingController(text: '7890');
  final _proxyUser = TextEditingController();
  final _proxyPassword = TextEditingController();

  bool _testing = false;
  String? _testResult;
  bool _testOk = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final m = widget.existing;
    if (m == null) return;
    _protocol = m.protocol;
    _name.text = m.name;
    _host.text = m.host;
    _port.text = m.port == 0 ? '' : '${m.port}';
    _user.text = m.username;
    _rootPath.text = m.rootPath.isEmpty ? '/' : m.rootPath;
    _bucket.text = m.bucket;
    _region.text = m.region;
    _pathStyle = m.pathStyle;
    _readOnly = m.readOnly;
    _anonymous = m.anonymous;
    _proxyEnabled = m.proxy.enabled;
    _proxyType = m.proxy.type;
    _proxyHost.text = m.proxy.host;
    _proxyPort.text = '${m.proxy.port}';
    _proxyUser.text = m.proxy.username;
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _host,
      _port,
      _user,
      _password,
      _rootPath,
      _bucket,
      _region,
      _proxyHost,
      _proxyPort,
      _proxyUser,
      _proxyPassword,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _onProtocolChanged(MountProtocol p) {
    setState(() {
      _protocol = p;
      _testResult = null;
      if (p != MountProtocol.local) {
        _port.text = '${p.defaultPort}';
      }
      if (p == MountProtocol.local && _name.text == '新挂载') {
        _name.text = '本地目录';
      }
      if (p == MountProtocol.s3 && _name.text == '新挂载') {
        _name.text = '对象存储';
      }
    });
  }

  bool get _isAnonymous => _protocol == MountProtocol.ftp && _anonymous;

  Mount _buildMount() => Mount(
        id: widget.existing?.id ?? 'm${DateTime.now().millisecondsSinceEpoch}',
        name: _name.text.trim().isEmpty ? _protocol.label : _name.text.trim(),
        protocol: _protocol,
        host: _host.text.trim(),
        port: int.tryParse(_port.text.trim()) ?? _protocol.defaultPort,
        username: _user.text.trim(),
        rootPath: _rootPath.text.trim().isEmpty ? '/' : _rootPath.text.trim(),
        bucket: _bucket.text.trim(),
        region: _region.text.trim(),
        pathStyle: _pathStyle,
        readOnly: _readOnly,
        anonymous: _protocol == MountProtocol.ftp && _anonymous,
        proxy: ProxyConfig(
          enabled: _proxyEnabled,
          type: _proxyType,
          host: _proxyHost.text.trim(),
          port: int.tryParse(_proxyPort.text.trim()) ?? 7890,
          username: _proxyUser.text.trim(),
        ),
        createdAt: widget.existing?.createdAt,
      );

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      final mount = _buildMount();
      // 编辑模式下密码可能留空：此时用已保存的凭据测，而不是拿空密码去撞。
      final count = _isEdit && _password.text.isEmpty
          ? await widget.state.testSavedMount(mount)
          : await testMount(
              mount,
              password: _password.text,
              proxyPassword: _proxyPassword.text,
            );
      setState(() {
        _testOk = true;
        _testResult = '连接成功 · 根目录 $count 项';
      });
    } catch (e) {
      setState(() {
        _testOk = false;
        _testResult = describeError(e);
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    final mount = _buildMount();
    if (mount.protocol != MountProtocol.local && mount.host.isEmpty) {
      setState(() {
        _testOk = false;
        _testResult = '请填写主机地址或 Endpoint';
      });
      return;
    }
    if (mount.protocol == MountProtocol.local && mount.rootPath.isEmpty) {
      setState(() {
        _testOk = false;
        _testResult = '请填写本地目录路径';
      });
      return;
    }
    try {
      if (_isEdit) {
        await widget.state.updateMount(
          mount,
          password: _password.text.isEmpty ? null : _password.text,
          proxyPassword: _proxyPassword.text.isEmpty ? null : _proxyPassword.text,
        );
      } else {
        await widget.state.addMount(
          mount,
          password: _password.text,
          proxyPassword: _proxyPassword.text,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testOk = false;
        _testResult = describeError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 720),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 16, 12),
              child: Row(
                children: [
                  Container(
                    width: uiSize(26),
                    height: uiSize(26),
                    decoration: BoxDecoration(
                      gradient: NimboColors.gradient,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(Icons.add_rounded, size: uiSize(15), color: Colors.white),
                  ),
                  const SizedBox(width: 10),
                  Text(_isEdit ? '编辑挂载' : '添加挂载',
                      style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800)),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    icon: const Icon(Icons.close_rounded, size: 18),
                    color: NimboColors.ink3,
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: NimboColors.line),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _protocolGrid(),
                    const SizedBox(height: 14),
                    _fields(),
                    const SizedBox(height: 6),
                    _proxySection(),
                    if (_testResult != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          color: _testOk ? const Color(0x1422C55E) : const Color(0x14F43F5E),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: _testOk ? const Color(0x3322C55E) : const Color(0x33F43F5E)),
                        ),
                        child: Row(
                          children: [
                            Icon(_testOk ? Icons.check_circle_outline : Icons.error_outline,
                                size: 14,
                                color: _testOk ? NimboColors.okInk : NimboColors.dangerInk),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(_testResult!,
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color:
                                          _testOk ? NimboColors.okInk : NimboColors.dangerInk)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const Divider(height: 1, color: NimboColors.line),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 16, 12),
              child: Row(
                children: [
                  const Icon(Icons.shield_outlined, size: 13, color: NimboColors.ink4),
                  const SizedBox(width: 5),
                  const Expanded(
                    child: Text('凭据只写入系统安全存储，不落配置文件',
                        style: TextStyle(fontSize: 10, color: NimboColors.ink3)),
                  ),
                  NimboButton(_testing ? '测试中…' : '测试连接',
                      kind: NimboButtonKind.secondary,
                      icon: Icons.bolt_rounded,
                      onPressed: _testing ? null : _test),
                  const SizedBox(width: 8),
                  NimboButton(_isEdit ? '保存修改' : '保存并连接',
                      kind: NimboButtonKind.primary,
                      icon: Icons.check_rounded,
                      onPressed: _save),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _protocolGrid() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final p in MountProtocol.values)
          InkWell(
            borderRadius: BorderRadius.circular(10),
            // 编辑时不允许换协议：凭据语义（密码 / AK+SK）与路径规则都不同，
            // 换协议更接近「删掉重建」，不如让用户重新添加一个。
            onTap: _isEdit ? null : () => _onProtocolChanged(p),
            child: Container(
              // 窄屏 + 放大字号后 116 放不下协议说明，按同一系数放宽。
              width: uiSize(116),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              decoration: BoxDecoration(
                color: _protocol == p ? const Color(0x0F38BDF8) : const Color(0xFFFCFDFF),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _protocol == p ? NimboColors.sky600 : const Color(0xFFDFE9F3),
                  width: _protocol == p ? 1.5 : 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ProtocolBadge(p),
                  const SizedBox(height: 6),
                  Text(p.hint,
                      style: const TextStyle(
                          fontSize: 9, fontWeight: FontWeight.w600, color: NimboColors.ink3)),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _field(String label, TextEditingController controller,
      {String? hint, bool obscure = false, TextInputType? keyboard, bool enabled = true}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FieldLabel(label),
          TextField(
            controller: controller,
            obscureText: obscure,
            keyboardType: keyboard,
            enabled: enabled,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: enabled ? null : NimboColors.ink4,
            ),
            decoration: nimboInput(hint: hint),
          ),
        ],
      ),
    );
  }

  Widget _fields() {
    if (_protocol == MountProtocol.local) {
      return Column(
        children: [
          _field('显示名称', _name),
          _field('目录路径', _rootPath, hint: 'D:\\Media 或 /storage/emulated/0/Download'),
          _switchRow('只读挂载', _readOnly, (v) => setState(() => _readOnly = v)),
          const SizedBox(height: 4),
          const Text('提示：Windows 可先把 SMB 共享映射成盘符，再从这里按本地目录接入。',
              style: TextStyle(fontSize: 10.5, height: 1.6, color: NimboColors.ink3)),
        ],
      );
    }

    return Column(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 3, child: _field('显示名称', _name)),
            const SizedBox(width: 10),
            Expanded(flex: 2, child: _field('端口', _port, keyboard: TextInputType.number)),
          ],
        ),
        _field(_protocol == MountProtocol.s3 ? 'Endpoint' : '主机地址', _host,
            hint: _protocol == MountProtocol.s3
                ? 's3.example.com 或 oss-cn-hangzhou.aliyuncs.com'
                : (_protocol == MountProtocol.webdav ? 'https://dav.example.com' : '192.168.1.20')),
        if (_protocol == MountProtocol.s3) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _field('Bucket', _bucket, hint: 'nimbo-backup')),
              const SizedBox(width: 10),
              Expanded(child: _field('Region（可空）', _region, hint: 'us-east-1')),
            ],
          ),
          _field('Access Key', _user),
          _field('Secret Key', _password,
              obscure: true, hint: _isEdit ? '留空表示不修改' : null),
          _field('根前缀（可空）', _rootPath, hint: '/media'),
          _switchRow('路径风格（path-style）', _pathStyle, (v) => setState(() => _pathStyle = v)),
          const SizedBox(height: 4),
          const Text('第三方自建 S3 建议开启；阿里云 OSS 等只支持虚拟托管，可关闭。',
              style: TextStyle(fontSize: 10.5, height: 1.6, color: NimboColors.ink3)),
        ] else ...[
          if (_protocol == MountProtocol.ftp)
            _switchRow('匿名登录（anonymous）', _anonymous, (v) => setState(() => _anonymous = v)),
          _field('用户名', _user, enabled: !_isAnonymous),
          _field('密码', _password,
              obscure: true,
              enabled: !_isAnonymous,
              hint: _isEdit ? '留空表示不修改' : null),
          _field('根路径（可空）', _rootPath, hint: '/'),
        ],
        _switchRow('只读挂载', _readOnly, (v) => setState(() => _readOnly = v)),
      ],
    );
  }

  Widget _proxySection() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFD),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: NimboColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Switch(
                value: _proxyEnabled,
                onChanged: (v) => setState(() => _proxyEnabled = v),
              ),
              const SizedBox(width: 4),
              const Text('独立代理',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(width: 8),
              const Text('仅对本挂载生效，不影响其他挂载',
                  style: TextStyle(fontSize: 10, color: NimboColors.ink3)),
            ],
          ),
          if (_proxyEnabled) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                for (final t in ProxyType.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(t.label, style: const TextStyle(fontSize: 10.5)),
                      selected: _proxyType == t,
                      onSelected: (_) => setState(() => _proxyType = t),
                      visualDensity: VisualDensity.compact,
                      selectedColor: NimboColors.navOnBg,
                      backgroundColor: Colors.white,
                      side: BorderSide(
                          color: _proxyType == t ? NimboColors.sky600 : NimboColors.line),
                      labelStyle: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: _proxyType == t ? NimboColors.navOn : NimboColors.ink2),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: _field('代理主机', _proxyHost, hint: '127.0.0.1')),
                const SizedBox(width: 10),
                Expanded(flex: 2, child: _field('代理端口', _proxyPort, keyboard: TextInputType.number)),
              ],
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _field('代理用户名（可空）', _proxyUser)),
                const SizedBox(width: 10),
                Expanded(child: _field('代理密码（可空）', _proxyPassword, obscure: true)),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _switchRow(String label, bool value, ValueChanged<bool> onChanged) {
    return Row(
      children: [
        Switch(
          value: value,
          onChanged: onChanged,
        ),
        Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      ],
    );
  }
}
