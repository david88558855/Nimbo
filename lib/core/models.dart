import 'package:flutter/material.dart';

enum MountProtocol { ftp, sftp, s3, webdav, local }

extension MountProtocolX on MountProtocol {
  String get id => name;

  String get label => switch (this) {
        MountProtocol.ftp => 'FTP',
        MountProtocol.sftp => 'SFTP',
        MountProtocol.s3 => 'S3',
        MountProtocol.webdav => 'WebDAV',
        MountProtocol.local => '本地',
      };

  String get hint => switch (this) {
        MountProtocol.ftp => '明文 / FTPS · 21',
        MountProtocol.sftp => 'SSH2 · 22',
        MountProtocol.s3 => 'S3 兼容 · 443',
        MountProtocol.webdav => 'HTTP / HTTPS · 443',
        MountProtocol.local => '本机 / 映射盘',
      };

  int get defaultPort => switch (this) {
        MountProtocol.ftp => 21,
        MountProtocol.sftp => 22,
        MountProtocol.s3 => 443,
        MountProtocol.webdav => 443,
        MountProtocol.local => 0,
      };

  bool get hasNetwork => this != MountProtocol.local;

  Color get color => switch (this) {
        MountProtocol.ftp => const Color(0xFFA9700A),
        MountProtocol.sftp => const Color(0xFF137A4B),
        MountProtocol.s3 => const Color(0xFF5B41D6),
        MountProtocol.webdav => const Color(0xFF0A8068),
        MountProtocol.local => const Color(0xFF4A6076),
      };

  Color get bg => switch (this) {
        MountProtocol.ftp => const Color(0x21D98A06),
        MountProtocol.sftp => const Color(0x2122C55E),
        MountProtocol.s3 => const Color(0x247C5CFC),
        MountProtocol.webdav => const Color(0x210DA98F),
        MountProtocol.local => const Color(0x2963788E),
      };

  static MountProtocol parse(String? v) {
    for (final p in MountProtocol.values) {
      if (p.name == v) return p;
    }
    return MountProtocol.local;
  }
}

enum ProxyType { http, socks5 }

extension ProxyTypeX on ProxyType {
  String get label => this == ProxyType.http ? 'HTTP' : 'SOCKS5';
  static ProxyType parse(String? v) => v == 'socks5' ? ProxyType.socks5 : ProxyType.http;
}

/// 代理是挂载的属性：一对一绑定，不存在全局代理。
class ProxyConfig {
  const ProxyConfig({
    this.enabled = false,
    this.type = ProxyType.http,
    this.host = '127.0.0.1',
    this.port = 7890,
    this.username = '',
    this.password = '',
  });

  final bool enabled;
  final ProxyType type;
  final String host;
  final int port;
  final String username;
  final String password;

  String get label => '${type.label} $host:$port';

  ProxyConfig copyWith({
    bool? enabled,
    ProxyType? type,
    String? host,
    int? port,
    String? username,
    String? password,
  }) =>
      ProxyConfig(
        enabled: enabled ?? this.enabled,
        type: type ?? this.type,
        host: host ?? this.host,
        port: port ?? this.port,
        username: username ?? this.username,
        password: password ?? this.password,
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'type': type.name,
        'host': host,
        'port': port,
        'username': username,
        // 密码不落配置文件
      };

  factory ProxyConfig.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const ProxyConfig();
    return ProxyConfig(
      enabled: j['enabled'] == true,
      type: ProxyTypeX.parse(j['type'] as String?),
      host: (j['host'] as String?) ?? '127.0.0.1',
      port: (j['port'] as num?)?.toInt() ?? 7890,
      username: (j['username'] as String?) ?? '',
    );
  }
}

class Mount {
  Mount({
    required this.id,
    required this.name,
    required this.protocol,
    this.host = '',
    this.port = 0,
    this.username = '',
    this.rootPath = '/',
    this.bucket = '',
    this.region = '',
    this.pathStyle = true,
    this.readOnly = false,
    this.proxy = const ProxyConfig(),
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  String name;
  final MountProtocol protocol;
  String host;
  int port;
  String username;
  String rootPath;
  String bucket;
  String region;
  bool pathStyle;
  bool readOnly;
  ProxyConfig proxy;
  final DateTime createdAt;

  String get subtitle {
    switch (protocol) {
      case MountProtocol.local:
        return rootPath;
      case MountProtocol.s3:
        return '$host/${bucket.isEmpty ? '—' : bucket}';
      default:
        return host.isEmpty ? '未配置' : '$host:$port';
    }
  }

  /// 文件树展示用的显示名（bucket 不进入目录层级）。
  String get displayRoot => protocol == MountProtocol.s3
      ? (rootPath.isEmpty || rootPath == '/' ? '/' : rootPath)
      : rootPath;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'protocol': protocol.name,
        'host': host,
        'port': port,
        'username': username,
        'rootPath': rootPath,
        'bucket': bucket,
        'region': region,
        'pathStyle': pathStyle,
        'readOnly': readOnly,
        'proxy': proxy.toJson(),
        'createdAt': createdAt.toIso8601String(),
      };

  factory Mount.fromJson(Map<String, dynamic> j) => Mount(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '未命名',
        protocol: MountProtocolX.parse(j['protocol'] as String?),
        host: (j['host'] as String?) ?? '',
        port: (j['port'] as num?)?.toInt() ?? 0,
        username: (j['username'] as String?) ?? '',
        rootPath: (j['rootPath'] as String?) ?? '/',
        bucket: (j['bucket'] as String?) ?? '',
        region: (j['region'] as String?) ?? '',
        pathStyle: j['pathStyle'] != false,
        readOnly: j['readOnly'] == true,
        proxy: ProxyConfig.fromJson(j['proxy'] as Map<String, dynamic>?),
        createdAt: DateTime.tryParse((j['createdAt'] as String?) ?? ''),
      );
}

class RemoteEntry {
  const RemoteEntry({
    required this.name,
    required this.path,
    required this.isDir,
    this.size = 0,
    this.modified,
  });

  final String name;
  final String path;
  final bool isDir;
  final int size;
  final DateTime? modified;

  String get extension {
    final i = name.lastIndexOf('.');
    return i > 0 ? name.substring(i + 1).toLowerCase() : '';
  }
}

class SpaceInfo {
  const SpaceInfo(this.total, this.free);
  final int total;
  final int free;
}

enum TransferStatus { queued, running, done, failed, paused }

extension TransferStatusX on TransferStatus {
  String get label => switch (this) {
        TransferStatus.queued => '排队中',
        TransferStatus.running => '传输中',
        TransferStatus.done => '已完成',
        TransferStatus.failed => '失败',
        TransferStatus.paused => '已暂停',
      };
}

class TransferTask {
  TransferTask({
    required this.id,
    required this.mountName,
    required this.name,
    required this.remotePath,
    required this.localPath,
    this.total = 0,
    this.status = TransferStatus.queued,
    this.error,
  });

  final String id;
  final String mountName;
  final String name;
  final String remotePath;
  final String localPath;
  int total;
  int transferred = 0;
  TransferStatus status;
  String? error;

  double get progress => total <= 0 ? 0 : (transferred / total).clamp(0.0, 1.0);
}
