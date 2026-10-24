/// S3 请求路径与 URL 编码的纯函数实现。
///
/// 单独拆出来有两个原因：
/// 1. **可以单测**：路径拼错是 S3 最常见的 404 来源，而驱动本身依赖网络，测不动；
/// 2. **一条路径真相**：SigV4 的 canonical URI、实际发出的 URL、`x-amz-copy-source`
///    用的都是同一套编码规则，散在驱动里迟早会不一致。
library;

import 'dart:convert';

/// S3 的 URI 编码：RFC 3986 unreserved 字符原样保留（含 `~`），其余按大写十六进制转义。
///
/// 与 `Uri.encodeComponent` 的区别：后者对 `+`、`~` 的处理与 S3 不一致，且转义大小写
/// 不保证；SigV4 的签名对编码结果大小写敏感，所以这里自己实现并单测。
String uriEncodeS3(String input) {
  final sb = StringBuffer();
  for (final b in utf8.encode(input)) {
    final unreserved = (b >= 65 && b <= 90) || // A-Z
        (b >= 97 && b <= 122) || // a-z
        (b >= 48 && b <= 57) || // 0-9
        b == 0x2D || // -
        b == 0x2E || // .
        b == 0x5F || // _
        b == 0x7E; // ~
    if (unreserved) {
      sb.writeCharCode(b);
    } else {
      sb.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return sb.toString();
}

/// 拼出请求路径（不含 query）。
///
/// - [endpointPath]：Endpoint 里的**路径前缀**，例如 `https://demo.foxel.cc/s3` 的 `/s3`。
///   很多自建/网关型 S3 都挂在子路径下，丢了它请求会打到站点根，表现为 404 —— 而且
///   返回的往往不是 S3 的 XML 错误，而是反代/框架的 404 页面。
/// - [pathStyle]：true 时桶名进路径（`/bucket/key`），false 时靠 `bucket.host`（`/key`）。
/// - [key]：桶内相对 key（不含前导斜杠、不含桶名、不含 [endpointPath]）。
/// - [dir]：目录语义，末尾补 `/`（S3 用零字节对象表示目录）。
String buildS3RequestPath({
  required String endpointPath,
  required bool pathStyle,
  required String bucket,
  required String key,
  bool dir = false,
}) {
  var prefix = endpointPath.trim();
  if (prefix.isNotEmpty && !prefix.startsWith('/')) prefix = '/$prefix';
  prefix = prefix.replaceAll(RegExp(r'/+$'), '');

  final encodedKey = key.isEmpty ? '' : key.split('/').map(uriEncodeS3).join('/');
  var withSlash =
      dir && encodedKey.isNotEmpty && !encodedKey.endsWith('/') ? '$encodedKey/' : encodedKey;

  final bucketPart = pathStyle ? '/${uriEncodeS3(bucket)}' : '';
  final head = '$prefix$bucketPart';
  if (withSlash.isEmpty) return head.isEmpty ? '/' : '$head/';
  if (!withSlash.startsWith('/')) withSlash = '/$withSlash';
  return '$head$withSlash';
}
