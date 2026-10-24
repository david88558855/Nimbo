import 'package:flutter_test/flutter_test.dart';
import 'package:nimbo/core/format.dart';
import 'package:nimbo/core/limiter.dart';
import 'package:nimbo/core/multipart_store.dart';
import 'package:nimbo/core/models.dart';
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
