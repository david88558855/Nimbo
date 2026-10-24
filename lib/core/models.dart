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
        MountProtocol.ftp => '明文 FTP · 21',
        MountProtocol.sftp => 'SSH2 · 22',
        // 端口写在地址里，别在协议说明里暗示有独立端口框。
        MountProtocol.s3 => 'S3 兼容 · HTTPS',
        MountProtocol.webdav => 'HTTP / HTTPS',
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

  /// 端口是否属于地址的一部分（HTTP 系协议）。
  ///
  /// S3 与 WebDAV 都跑在 HTTP 上，端口本来就写进 URL（`https://host:8443`）。
  /// 表单对这两个协议**不再提供独立端口输入框**，`Mount.port` 保存为 0，
  /// 由 `core/endpoint.dart` 的 `parseEndpoint()` 从地址里解析。
  bool get portInHost => this == MountProtocol.s3 || this == MountProtocol.webdav;

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
    this.anonymous = false,
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

  /// FTP 匿名登录：不发送真实账号，用 anonymous / anonymous@ 登录。
  bool anonymous;

  ProxyConfig proxy;
  final DateTime createdAt;

  String get subtitle {
    switch (protocol) {
      case MountProtocol.local:
        return rootPath;
      case MountProtocol.s3:
        return '$host/${bucket.isEmpty ? '—' : bucket}';
      default:
        // 端口归入地址后 port 可能是 0，别显示成 `dav.example.com:0`。
        return host.isEmpty ? '未配置' : (port > 0 ? '$host:$port' : host);
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
        'anonymous': anonymous,
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
        anonymous: j['anonymous'] == true,
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

enum TransferDir { upload, download }

extension TransferDirX on TransferDir {
  String get label => this == TransferDir.upload ? '上传' : '下载';
}

/// 一个传输任务。由 [TransferManager] 持有并按队列推进。
///
/// 每个任务自带一条独立连接（协议侧互不阻塞），因此上传与下载
/// 可以同时进行，也可以针对不同挂载并行。
class TransferTask {
  TransferTask({
    required this.id,
    required this.mountId,
    required this.mountName,
    required this.name,
    required this.remotePath,
    required this.localPath,
    required this.dir,
    this.total = 0,
    this.status = TransferStatus.queued,
    this.error,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  final String mountId;
  final String mountName;
  final String name;
  final String remotePath;
  final String localPath;
  final TransferDir dir;
  final DateTime createdAt;

  int total;
  int transferred = 0;
  TransferStatus status;
  String? error;

  /// 平滑后的瞬时速度（字节/秒）。
  double speed = 0;
  DateTime? finishedAt;

  /// 用户请求中止（暂停 / 取消）：进度回调会抛出，从而中断驱动内部的循环。
  bool abort = false;

  /// 上次中断时的字节数，> 0 表示下次启动尝试续传（实际起点由驱动侧复核）。
  int resumeOffset = 0;

  /// 当前挂载是否支持续传，连接建立后由驱动能力回填，仅用于界面提示。
  bool resumable = false;

  // 速度采样，仅运行期使用。
  int sampleBytes = 0;
  DateTime? sampleAt;

  bool get isRunning => status == TransferStatus.running;
  bool get isActive =>
      status == TransferStatus.running || status == TransferStatus.queued;

  /// 协议没给出总大小时（FTP 无 SIZE、分片上传前）进度条应画不确定态，
  /// 否则会一直停在 0% 让人以为卡住了。
  bool get hasTotal => total > 0;

  double get progress => total <= 0 ? 0 : (transferred / total).clamp(0.0, 1.0);

  /// 交给 `LinearProgressIndicator` 的值：null = 不确定态。
  double? get indicatorValue => total <= 0 ? null : progress;

  /// 剩余时间，速度未知时返回 null。
  Duration? get remaining {
    if (speed <= 0 || total <= 0 || transferred >= total) return null;
    final secs = ((total - transferred) / speed).round();
    if (secs <= 0 || secs > 86400 * 7) return null;
    return Duration(seconds: secs);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'mountId': mountId,
        'mountName': mountName,
        'name': name,
        'remotePath': remotePath,
        'localPath': localPath,
        'dir': dir.name,
        'total': total,
        'transferred': transferred,
        'status': status.name,
        'error': error,
        'resumeOffset': resumeOffset,
        'resumable': resumable,
        'createdAt': createdAt.toIso8601String(),
        'finishedAt': finishedAt?.toIso8601String(),
      };

  factory TransferTask.fromJson(Map<String, dynamic> j) {
    final task = TransferTask(
      id: (j['id'] as String?) ?? '',
      mountId: (j['mountId'] as String?) ?? '',
      mountName: (j['mountName'] as String?) ?? '',
      name: (j['name'] as String?) ?? '',
      remotePath: (j['remotePath'] as String?) ?? '/',
      localPath: (j['localPath'] as String?) ?? '',
      dir: j['dir'] == 'upload' ? TransferDir.upload : TransferDir.download,
      total: (j['total'] as num?)?.toInt() ?? 0,
      status: TransferStatus.values.firstWhere(
        (s) => s.name == j['status'],
        orElse: () => TransferStatus.paused,
      ),
      error: j['error'] as String?,
      createdAt: DateTime.tryParse((j['createdAt'] as String?) ?? ''),
    );
    task.transferred = (j['transferred'] as num?)?.toInt() ?? 0;
    task.resumeOffset = (j['resumeOffset'] as num?)?.toInt() ?? 0;
    // 老版本记录没有这个字段：保守按「不支持续传」处理，界面不显示续传提示。
    task.resumable = j['resumable'] == true;
    task.finishedAt = DateTime.tryParse((j['finishedAt'] as String?) ?? '');
    return task;
  }
}
