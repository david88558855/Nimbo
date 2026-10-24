import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../core/models.dart';
import '../core/endpoint.dart';
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

  /// 用户是否手动改过「显示名称」。没改过时，名称跟着地址/路径/bucket 自动更新；
  /// 一旦手动改过就完全由用户决定，不再被覆盖。
  bool _nameTouched = false;

  /// 程序自己写 controller 时置位，避免把自己的赋值当成「用户输入」。
  bool _syncingName = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final m = widget.existing;
    if (m == null) {
      // 新建：给一个由当前协议推导的默认名，并让它在用户输入地址时自动跟着变。
      _applySuggestedName();
      _name.addListener(_onNameTyped);
      _host.addListener(_refreshSuggestedName);
      _bucket.addListener(_refreshSuggestedName);
      _rootPath.addListener(_refreshSuggestedName);
      return;
    }
    // 编辑：名称是用户既有的值，不参与自动生成。
    _nameTouched = true;
    _protocol = m.protocol;
    _name.text = m.name;
    // 端口归入地址的协议（S3 / WebDAV）：老配置若把端口存在独立字段里，
    // 这里折进地址，否则隐藏端口框后一保存就把端口丢了。
    _host.text = m.protocol.portInHost
        ? _hostWithPort(m.host, m.port)
        : m.host;
    // HTTP 系协议的端口已折进地址，端口框不再显示，也不留残留值。
    _port.text = (m.port == 0 || m.protocol.portInHost) ? '' : '${m.port}';
    _user.text = m.username;
    _rootPath.text = m.rootPath.isEmpty ? '/' : m.rootPath;
    _bucket.text = m.bucket;
    _region.text = m.region;
    _pathStyle = m.pathStyle;
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
      if (p.portInHost) {
        // 端口写在地址里，独立端口框不显示 —— 顺手清掉残留值，
        // 否则切回 FTP/SFTP 时会把上一个协议的端口带过去。
        _port.clear();
      } else if (p != MountProtocol.local) {
        _port.text = '${p.defaultPort}';
      } else {
        _port.clear();
      }
      // 名称没被手动改过就按新协议重新推导（默认值跟着协议/地址走）。
      _applySuggestedName();
    });
  }

  bool get _isAnonymous => _protocol == MountProtocol.ftp && _anonymous;

  // ---------- 显示名称 ----------

  void _onNameTyped() {
    if (_syncingName) return;
    _nameTouched = true;
  }

  void _refreshSuggestedName() {
    if (_nameTouched) return;
    _applySuggestedName();
  }

  /// 把默认名称写进输入框（不标记为「用户改过」）。
  void _applySuggestedName() {
    final next = _suggestedName();
    if (_name.text == next) return;
    _syncingName = true;
    _name.text = next;
    _syncingName = false;
  }

  /// 默认显示名称：**跟着用户已经填了什么走**，而不是写死一个「新挂载」。
  ///
  /// - 本地：目录最后一段（`D://Media` → `Media`；盘符根 → `本地磁盘 D`）
  /// - S3：优先 bucket，其次主机名
  /// - WebDAV / FTP / SFTP：主机名（去掉 `http(s)://`、端口与路径）
  /// - 什么都没有：`<协议> 挂载`
  String _suggestedName() {
    switch (_protocol) {
      case MountProtocol.local:
        final parts = _rootPath.text
            .trim()
            .split(RegExp(r'[\\/]'))
            .where((e) => e.trim().isNotEmpty)
            .toList();
        if (parts.isEmpty) return '本地目录';
        final tail = parts.last.trim();
        // `D:` 这种盘符根没有目录名，用「本地磁盘 D」
        if (tail.length == 2 && tail.endsWith(':')) {
          return '本地磁盘 ${tail[0].toUpperCase()}';
        }
        return tail;
      case MountProtocol.s3:
        final bucket = _bucket.text.trim();
        if (bucket.isNotEmpty) return bucket;
        final host = _hostLabel();
        return host.isEmpty ? 'S3 存储' : host;
      default:
        final host = _hostLabel();
        return host.isEmpty ? '${_protocol.label} 挂载' : host;
    }
  }

  /// 从地址里取主机名；解析不了就原样返回（用户可能还在输入过程中）。
  String _hostLabel() {
    final raw = _host.text.trim();
    if (raw.isEmpty) return '';
    try {
      return parseEndpoint(raw).host;
    } on FormatException {
      return raw;
    }
  }

  /// 保存/测试前的兜底：名称为空就补上默认值（保证「必填」不会误拦）。
  void _ensureName() {
    if (_name.text.trim().isEmpty) _applySuggestedName();
  }

  Mount _buildMount() => Mount(
        id: widget.existing?.id ?? 'm${DateTime.now().millisecondsSinceEpoch}',
        name: _name.text.trim().isEmpty ? _suggestedName() : _name.text.trim(),
        protocol: _protocol,
        host: _host.text.trim(),
        // S3 / WebDAV 的端口属于地址，mount.port 固定存 0（不落残留字段）；
        // FTP / SFTP 仍用独立端口框，留空回落到协议默认端口。
        port: _protocol.portInHost
            ? 0
            : (int.tryParse(_port.text.trim()) ?? _protocol.defaultPort),
        username: _user.text.trim(),
        rootPath: _rootPath.text.trim().isEmpty ? '/' : _rootPath.text.trim(),
        bucket: _bucket.text.trim(),
        region: _region.text.trim(),
        pathStyle: _pathStyle,
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
    _ensureName();
    final mount = _buildMount();
    final invalid = _validationError(mount);
    if (invalid != null) {
      setState(() {
        _testOk = false;
        _testResult = invalid;
      });
      return;
    }
    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
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

  /// 「测试连接」与「保存」共用同一套校验。
  ///
  /// 分开写会出现「测试通过、保存报错」这种前后不一致——端口校验尤其容易踩，
  /// 所以错误信息统一从这里返回，界面只负责展示。
  String? _validationError(Mount mount) {
    // 名称有默认值，正常情况下不会为空；这里只防「手动清空后直接保存」。
    if (mount.name.trim().isEmpty) return '请填写显示名称';
    if (mount.protocol == MountProtocol.local) {
      return mount.rootPath.trim().isEmpty ? '请填写本地目录路径' : null;
    }
    if (mount.host.isEmpty) {
      return switch (mount.protocol) {
        MountProtocol.s3 => '请填写 Endpoint，例如 https://s3.example.com:9000',
        MountProtocol.webdav => '请填写服务器地址，例如 https://dav.example.com:8443/dav',
        _ => '请填写主机地址，例如 192.168.1.20',
      };
    }
    if (mount.protocol.portInHost) {
      // 端口写在地址里：用驱动同一套解析规则验一遍，避免保存成功、连的时候才报错。
      try {
        parseEndpoint(mount.host);
      } on FormatException catch (e) {
        return '${e.message}。端口请写在地址里，例如 https://dav.example.com:8443';
      }
      return null;
    }
    // FTP / SFTP：端口仍是独立输入框，留空代表用协议默认端口。
    final raw = _port.text.trim();
    if (raw.isEmpty) return null;
    final port = int.tryParse(raw);
    if (port == null || port < 1 || port > 65535) {
      return '端口必须是 1–65535 之间的数字（留空则用默认 ${mount.protocol.defaultPort}）';
    }
    return null;
  }

  Future<void> _save() async {
    _ensureName();
    final mount = _buildMount();
    final invalid = _validationError(mount);
    if (invalid != null) {
      setState(() {
        _testOk = false;
        _testResult = invalid;
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
              // 左右内边距对称：原来左 20 / 右 16 会让居中后的按钮看着偏左。
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Row(
                // 居中而不是靠右：窄屏（放大字号后）靠右会贴着右边界，看着像错位。
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // 底部只留操作按钮：原来的「凭据写入安全存储」说明已移除。
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

  /// 把老配置里独立保存的端口折进地址（只在编辑 S3 / WebDAV 时用）。
  ///
  /// 历史版本这两个协议也有独立端口框，地址里可能没写端口。隐藏端口框后如果不折进去，
  /// 保存一次就把端口丢了 —— 表现为「编辑了一下名字，结果连不上了」。
  static String _hostWithPort(String host, int port) {
    final h = host.trim();
    if (port <= 0 || h.isEmpty) return host;
    try {
      final ep = parseEndpoint(h);
      if (ep.explicitPort) return h; // 地址里已经写了端口，以地址为准
      return '${ep.origin}:$port${ep.basePath}';
    } on FormatException {
      // 地址本身不合法：保持原样，让保存时的校验给出明确提示。
      return host;
    }
  }

  /// HTTP 系协议：把「地址 → 实际连接点」实时解析出来展示。
  Widget _endpointPreview() {
    final raw = _host.text.trim();
    if (raw.isEmpty) return const SizedBox.shrink();
    var ok = true;
    String text;
    try {
      final ep = parseEndpoint(raw);
      text = '将连接 ${ep.summary} · 端口 ${ep.port}'
          '${ep.explicitPort ? '（地址中指定）' : '（默认）'}';
    } on FormatException catch (e) {
      ok = false;
      text = e.message;
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(ok ? Icons.link_rounded : Icons.error_outline_rounded,
              size: 12, color: ok ? NimboColors.ink4 : NimboColors.dangerInk),
          const SizedBox(width: 5),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 9.5,
                    height: 1.5,
                    fontWeight: FontWeight.w600,
                    color: ok ? NimboColors.ink3 : NimboColors.dangerInk)),
          ),
        ],
      ),
    );
  }

  Widget _fields() {
    if (_protocol == MountProtocol.local) {
      return Column(
        children: [
          _field('显示名称', _name, hint: '留空按地址自动生成'),
          _field('目录路径', _rootPath, hint: 'D:\\Media 或 /storage/emulated/0/Download'),
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
            Expanded(
                flex: _protocol.portInHost ? 1 : 3,
                child: _field('显示名称', _name, hint: '留空按地址自动生成')),
            // S3 / WebDAV 的端口属于地址，不再给独立端口框（避免与地址里的端口打架）。
            if (!_protocol.portInHost) ...[
              const SizedBox(width: 10),
              Expanded(flex: 2, child: _field('端口', _port, keyboard: TextInputType.number)),
            ],
          ],
        ),
        _field(_protocol == MountProtocol.s3 ? 'Endpoint' : '主机地址', _host,
            hint: _protocol == MountProtocol.s3
                ? 'https://s3.example.com:9000 或 oss-cn-hangzhou.aliyuncs.com'
                : (_protocol == MountProtocol.webdav
                    ? 'https://dav.example.com:8443/dav'
                    : '192.168.1.20')),
        // 端口藏进地址后，这里是用户确认「端口有没有被认出来」的唯一入口。
        if (_protocol.portInHost)
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _host,
            builder: (_, __, ___) => _endpointPreview(),
          ),
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
