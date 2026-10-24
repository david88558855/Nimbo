import 'dart:async';
import 'dart:math' as math;

/// 令牌桶：按字节限速。
///
/// 设计取舍：
/// - **放在全局单例里**，而不是顺着 `ProgressFn` 往下传。原因是 dio 的上传进度
///   回调是同步的（`onSendProgress`），无法在里面 `await`；而各驱动的读写循环
///   本身就是 async 的，直接在自己循环里向桶要令牌最省改动，也让所有协议共用一套限速。
/// - **只在循环里 `await`，不做精确定时**：令牌不足时睡一小段（最多 1 秒），
///   醒来再补。误差在几十毫秒量级，对「别把上行带宽打满」这个目标足够。
class TokenBucket {
  /// 构造时直接给定初始速率（字节/秒，0 = 不限）。
  TokenBucket(int rate) : _rate = rate <= 0 ? 0 : rate;

  int _rate;
  double _tokens = 0;
  DateTime _stamp = DateTime.now();

  /// 字节/秒；0 表示不限速。
  int get rate => _rate;

  set rate(int value) {
    _rate = value <= 0 ? 0 : value;
    _tokens = 0;
    _stamp = DateTime.now();
  }

  bool get limited => _rate > 0;

  /// 桶容量取「1 秒的量」，至少 64 KB，避免极低限速时每块都要等很久。
  int get _capacity => math.max(_rate, 64 * 1024);

  void _refill() {
    final now = DateTime.now();
    final dt = now.difference(_stamp).inMicroseconds / 1e6;
    if (dt <= 0) return;
    _stamp = now;
    _tokens = math.min(_capacity.toDouble(), _tokens + dt * _rate);
  }

  /// 取 [bytes] 个令牌，不足则等待。**必须**在驱动的长循环里调用，
  /// 否则该协议既不限速、也无法被暂停中断。
  Future<void> take(int bytes) async {
    if (_rate <= 0 || bytes <= 0) return;
    var remain = bytes;
    while (remain > 0) {
      _refill();
      final want = math.min(remain, _capacity);
      if (_tokens >= want) {
        _tokens -= want;
        remain -= want;
        continue;
      }
      final need = want - _tokens;
      final waitMs = (need * 1000 / _rate).ceil().clamp(1, 1000).toInt();
      await Future<void>.delayed(Duration(milliseconds: waitMs));
    }
  }
}

/// 全局限速器：上传与下载各一个桶，按设置页的两个输入框配置。
class TransferLimiter {
  TransferLimiter._();

  static final TransferLimiter instance = TransferLimiter._();

  final TokenBucket upload = TokenBucket(0);
  final TokenBucket download = TokenBucket(0);

  /// 入参单位 KB/s，0 表示不限。
  void configure({required int uploadKbps, required int downloadKbps}) {
    upload.rate = uploadKbps <= 0 ? 0 : uploadKbps * 1024;
    download.rate = downloadKbps <= 0 ? 0 : downloadKbps * 1024;
  }

  bool get uploadLimited => upload.limited;
  bool get downloadLimited => download.limited;
}

/// 给 dio 的上传/下载流套一层限速：读一块、要一块令牌、放行。
///
/// 用于「把整个 Stream 一次性交给 dio」的场景（WebDAV 上传、S3 下载回退），
/// 那里没有我们自己的循环，只能靠这层包装来限速。
Stream<List<int>> throttleStream(Stream<List<int>> source, TokenBucket bucket) async* {
  if (!bucket.limited) {
    yield* source;
    return;
  }
  await for (final chunk in source) {
    await bucket.take(chunk.length);
    yield chunk;
  }
}
