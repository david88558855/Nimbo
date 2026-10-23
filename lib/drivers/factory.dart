import '../core/models.dart';
import '../core/store.dart';
import 'ftp_driver.dart';
import 'local_driver.dart';
import 's3_driver.dart';
import 'sftp_driver.dart';
import 'storage_driver.dart';
import 'webdav_driver.dart';

/// 依据挂载配置构造驱动：凭据从系统安全存储取，代理密码同理。
Future<StorageDriver> createDriver(Mount mount) async {
  final password = await SecureStore.read(mount.id);
  final proxyPassword = await SecureStore.read(mount.id, field: 'proxyPassword');
  final proxy = mount.proxy.copyWith(password: proxyPassword);

  switch (mount.protocol) {
    case MountProtocol.local:
      return LocalDriver(mount);
    case MountProtocol.webdav:
      return WebDavDriver(mount, password: password, proxy: proxy);
    case MountProtocol.s3:
      return S3Driver(mount, accessKey: mount.username, secretKey: password, proxy: proxy);
    case MountProtocol.ftp:
      return FtpDriver(mount, password: password, proxy: proxy);
    case MountProtocol.sftp:
      return SftpDriver(mount, password: password, proxy: proxy);
  }
}

/// 连接测试：只连一次、列一次根目录，然后释放。
Future<int> testMount(Mount mount, {String? password, String? proxyPassword}) async {
  final resolved = mount.proxy.copyWith(password: proxyPassword ?? mount.proxy.password);
  // 不能直接改调用方的 mount：会把临时输入的凭据写进已保存的挂载对象
  final probeMount = Mount.fromJson(mount.toJson())..proxy = resolved;
  final StorageDriver driver;
  switch (probeMount.protocol) {
    case MountProtocol.local:
      driver = LocalDriver(probeMount);
    case MountProtocol.webdav:
      driver = WebDavDriver(probeMount, password: password ?? '', proxy: resolved);
    case MountProtocol.s3:
      driver = S3Driver(probeMount,
          accessKey: probeMount.username, secretKey: password ?? '', proxy: resolved);
    case MountProtocol.ftp:
      driver = FtpDriver(probeMount, password: password ?? '', proxy: resolved);
    case MountProtocol.sftp:
      driver = SftpDriver(probeMount, password: password ?? '', proxy: resolved);
  }
  try {
    await driver.connect();
    return await driver.probe();
  } finally {
    await driver.close();
  }
}
