import 'package:flutter_test/flutter_test.dart';
import 'package:nimbo/core/endpoint.dart';
import 'package:nimbo/core/format.dart';
import 'package:nimbo/core/limiter.dart';
import 'package:nimbo/core/multipart_store.dart';
import 'package:nimbo/core/models.dart';
import 'package:nimbo/core/upload_checkpoint.dart';
import 'package:nimbo/drivers/errors.dart';
import 'package:nimbo/drivers/storage_driver.dart';

/// 纯逻辑单测：不碰文件系统、不碰网络、不依赖平台插件，
/// 因此可以在 CI 的 analyze job 里直接 `flutter test`。
void main() {
  group('路径工具', () {
    test('joinPath 保持单前导斜杠', () {
      expect(joinPath('/', 'a'), '/a');
      expect(joinPath('/a', 'b'), '/a/b');
      expect(joinPath('/a/', 'b'), '/a/b');
      expect(joinPath('', 'a'), '/a');
    });

    test('parentPath 逐级回退到根', () {
      expect(parentPath('/a/b/c'), '/a/b');
      expect(parentPath('/a'), '/');
      expect(parentPath('/'), '/');
      expect(parentPath(''), '/');
    });

    test('splitPath 丢掉空段', () {
      expect(splitPath('/a/b/'), ['a', 'b']);
      expect(splitPath('/'), isEmpty);
    });

    test('normalizePath 合并重复分隔符并去掉尾斜杠', () {
      expect(normalizePath('a//b/'), '/a/b');
      expect(normalizePath(''), '/');
      expect(normalizePath('/'), '/');
    });

    test('sanitizeName 替换 Windows 非法字符', () {
      expect(sanitizeName('a/b\\c:d*e?f"g<h>i|j'), 'a_b_c_d_e_f_g_h_i_j');
      expect(sanitizeName('   '), 'unnamed');
    });
  });

  group('服务器地址解析（S3 / WebDAV）', () {
    test('没写协议时按 https 补，端口取默认', () {
      final ep = parseEndpoint('dav.example.com');
      expect(ep.scheme, 'https');
      expect(ep.host, 'dav.example.com');
      expect(ep.port, 443);
      expect(ep.explicitPort, isFalse);
      expect(ep.url, 'https://dav.example.com');
    });

    test('http 默认 80', () {
      final ep = parseEndpoint('http://dav.example.com');
      expect(ep.port, 80);
      expect(ep.url, 'http://dav.example.com');
    });

    test('地址里写端口：以地址为准并保留基础路径', () {
      final ep = parseEndpoint('https://dav.example.com:8443/dav/');
      expect(ep.host, 'dav.example.com');
      expect(ep.port, 8443);
      expect(ep.explicitPort, isTrue);
      expect(ep.basePath, '/dav');
      expect(ep.url, 'https://dav.example.com:8443/dav');
    });

    test('无协议但写了端口', () {
      final ep = parseEndpoint('s3.example.com:9000');
      expect(ep.scheme, 'https');
      expect(ep.host, 's3.example.com');
      expect(ep.port, 9000);
      expect(ep.explicitPort, isTrue);
    });

    test('老配置的独立端口作为兜底', () {
      final ep = parseEndpoint('https://dav.example.com', fallbackPort: 8443);
      expect(ep.port, 8443);
      expect(ep.explicitPort, isTrue);
      expect(ep.url, 'https://dav.example.com:8443');
    });

    test('地址里的端口优先于兜底端口', () {
      final ep = parseEndpoint('https://dav.example.com:9443', fallbackPort: 8443);
      expect(ep.port, 9443);
    });

    test('非法输入抛 FormatException', () {
      expect(() => parseEndpoint(''), throwsFormatException);
      expect(() => parseEndpoint('https://'), throwsFormatException);
      expect(() => parseEndpoint('ftp://host'), throwsFormatException);
      expect(() => parseEndpoint('https://host:0'), throwsFormatException);
      expect(() => parseEndpoint('https://host:99999'), throwsFormatException);
    });
  });

  group('令牌桶', () {
    test('0 表示不限速', () {
      final bucket = TokenBucket(0);
      expect(bucket.limited, isFalse);
      expect(bucket.rate, 0);
    });

    test('负数被归一化成不限速', () {
      final bucket = TokenBucket(-1);
      expect(bucket.rate, 0);
      bucket.rate = 2048;
      expect(bucket.rate, 2048);
      bucket.rate = -10;
      expect(bucket.rate, 0);
    });

    test('不限速时取令牌立即返回', () async {
      final bucket = TokenBucket(0);
      await bucket.take(1 << 20);
    });

    test('全局限速器按 KB/s 换算成字节/秒', () {
      TransferLimiter.instance.configure(uploadKbps: 512, downloadKbps: 0);
      expect(TransferLimiter.instance.upload.rate, 512 * 1024);
      expect(TransferLimiter.instance.download.rate, 0);
      expect(TransferLimiter.instance.uploadLimited, isTrue);
      expect(TransferLimiter.instance.downloadLimited, isFalse);
      // 复位，避免影响同进程内的其他用例
      TransferLimiter.instance.configure(uploadKbps: 0, downloadKbps: 0);
    });
  });

  group('S3 分片状态', () {
    test('序列化往返保留分片 ETag', () {
      final state = MultipartState(
        uploadId: 'upload-1',
        length: 100 * 1024 * 1024,
        partSize: 8 * 1024 * 1024,
        parts: {1: 'etag-a', 2: 'etag-b'},
      );
      final restored = MultipartState.fromJson(state.toJson());
      expect(restored, isNotNull);
      expect(restored!.uploadId, 'upload-1');
      expect(restored.length, state.length);
      expect(restored.partSize, state.partSize);
      expect(restored.parts, {1: 'etag-a', 2: 'etag-b'});
    });

    test('缺少 uploadId 的状态视为无效', () {
      expect(MultipartState.fromJson({'length': 1}), isNull);
      expect(MultipartState.fromJson({'uploadId': ''}), isNull);
    });
  });

  group('WebDAV 上传断点', () {
    test('序列化往返', () {
      final cp = UploadCheckpoint(length: 42, offset: 17);
      final restored = UploadCheckpoint.fromJson(cp.toJson());
      expect(restored, isNotNull);
      expect(restored!.length, 42);
      expect(restored.offset, 17);
    });

    test('缺少长度或长度非法时视为无效', () {
      // 断点必须和「文件总长度」绑定，否则会把两个不同文件拼在一起。
      expect(UploadCheckpoint.fromJson({}), isNull);
      expect(UploadCheckpoint.fromJson({'length': 0}), isNull);
      expect(UploadCheckpoint.fromJson({'length': -1}), isNull);
    });

    test('offset 缺省为 0', () {
      final cp = UploadCheckpoint.fromJson({'length': 10});
      expect(cp, isNotNull);
      expect(cp!.offset, 0);
    });
  });

  group('错误文案', () {
    test('按 kind 追加上可执行建议', () {
      final text = describeError(DriverException('凭据被拒绝', kind: DriverErrorKind.auth));
      expect(text, contains('凭据被拒绝'));
      expect(text, contains('Access Key'));
    });

    test('未知类型不吞掉原文', () {
      expect(describeError(StateError('boom')), contains('boom'));
    });

    test('长文案按传输卡片截断', () {
      final long = 'x' * 500;
      final short = shortError(DriverException(long));
      expect(short.length, lessThanOrEqualTo(201));
      expect(short.endsWith('…'), isTrue);
    });
  });

  group('传输任务', () {
    test('未知总大小不画百分比', () {
      final task = TransferTask(
        id: '1',
        mountId: 'm',
        mountName: 'n',
        name: 'f',
        remotePath: '/f',
        localPath: '/tmp/f',
        dir: TransferDir.download,
      );
      expect(task.hasTotal, isFalse);
      expect(task.indicatorValue, isNull);
      task.total = 100;
      task.transferred = 40;
      expect(task.indicatorValue, 0.4);
    });

    test('持久化保留续传能力标记', () {
      final task = TransferTask(
        id: '1',
        mountId: 'm',
        mountName: 'n',
        name: 'f',
        remotePath: '/f',
        localPath: '/tmp/f',
        dir: TransferDir.upload,
      )..resumable = true;
      expect(TransferTask.fromJson(task.toJson()).resumable, isTrue);
    });
  });
}
