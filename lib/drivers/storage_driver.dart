import 'dart:typed_data';

import '../core/models.dart';

typedef ProgressFn = void Function(int transferred, int total);

/// 断点续传能力。下载续传依赖协议侧的偏移读取（HTTP Range / FTP REST /
/// SFTP offset），上传续传还额外要求「远端已有字节数可查询且可追加」。
enum ResumeSupport {
  none,
  download,
  upload,
  both;

  bool get canDownload => this == ResumeSupport.download || this == ResumeSupport.both;
  bool get canUpload => this == ResumeSupport.upload || this == ResumeSupport.both;
}

enum DriverErrorKind { auth, notFound, permission, network, proxy, unsupported, unknown }

class DriverException implements Exception {
  DriverException(this.message, {this.kind = DriverErrorKind.unknown});

  final String message;
  final DriverErrorKind kind;

  @override
  String toString() => message;
}

class Capability {
  const Capability({
    this.space = false,
    this.move = true,
    this.checksum = false,
    this.proxy = true,
  });

  final bool space;
  final bool move;
  final bool checksum;
  final bool proxy;
}

/// 五类存储的统一接口：UI 与传输层只依赖它，不感知具体协议。
abstract class StorageDriver {
  StorageDriver(this.mount);

  final Mount mount;

  String get scheme;
  Capability get caps;

  /// 断点续传支持度，默认都不支持。
  ResumeSupport get resume => ResumeSupport.none;

  /// 建立会话（HTTP 类协议是惰性的，这里只做必要的握手）。
  Future<void> connect();

  Future<void> close();

  /// path 是挂载内的绝对路径，例如 `/影视`。
  Future<List<RemoteEntry>> list(String path);

  /// 容量：协议不支持时返回 null，UI 显示「未知」。
  Future<SpaceInfo?> space();

  Future<Uint8List> readAll(String path);

  /// [resumeFrom] > 0 表示本地文件已存在这么多字节，从该位置继续写。
  /// 未实现续传的驱动必须忽略该参数并从头写（调用方负责清理）。
  Future<void> downloadTo(String remotePath, String localFile,
      {ProgressFn? onProgress, int resumeFrom = 0});

  /// [resumeFrom] > 0 表示远端文件已有这么多字节，从该位置继续追加。
  Future<void> uploadFile(String localFile, String remotePath,
      {ProgressFn? onProgress, int resumeFrom = 0});

  /// 远端文件大小；不存在或不支持时返回 -1（用于上传续传前的校验）。
  Future<int> sizeOf(String path) async => -1;

  Future<void> mkdir(String path);

  Future<void> removeEntry(RemoteEntry entry);

  Future<void> move(String from, String to);

  /// 连接测试：列一次根目录，返回条目数。
  Future<int> probe() async {
    final items = await list('/');
    return items.length;
  }
}
