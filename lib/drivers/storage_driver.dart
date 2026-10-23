import 'dart:typed_data';

import '../core/models.dart';

typedef ProgressFn = void Function(int transferred, int total);

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

  /// 建立会话（HTTP 类协议是惰性的，这里只做必要的握手）。
  Future<void> connect();

  Future<void> close();

  /// path 是挂载内的绝对路径，例如 `/影视`。
  Future<List<RemoteEntry>> list(String path);

  /// 容量：协议不支持时返回 null，UI 显示「未知」。
  Future<SpaceInfo?> space();

  Future<Uint8List> readAll(String path);

  Future<void> downloadTo(String remotePath, String localFile, {ProgressFn? onProgress});

  Future<void> uploadFile(String localFile, String remotePath, {ProgressFn? onProgress});

  Future<void> mkdir(String path);

  Future<void> removeEntry(RemoteEntry entry);

  Future<void> move(String from, String to);

  /// 连接测试：列一次根目录，返回条目数。
  Future<int> probe() async {
    final items = await list('/');
    return items.length;
  }
}
