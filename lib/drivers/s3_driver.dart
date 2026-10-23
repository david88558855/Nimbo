import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:xml/xml.dart';

import '../core/format.dart';
import '../core/models.dart';
import 'net.dart';
import 'storage_driver.dart';

/// S3 兼容：SigV4 自行实现（不引第三方 SDK）。
/// 寻址默认 path-style，可按挂载切到 virtual-hosted —— 见 docs/s3-addressing-analysis.md。
class S3Driver extends StorageDriver {
  S3Driver(super.mount, {required this.accessKey, required this.secretKey, required this.proxy});

  final String accessKey;
  final String secretKey;
  final ProxyConfig proxy;

  late final Dio _dio;
  late final String _scheme;
  late final String _host;
  late final int _port;

  static const _emptyHash = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

  @override
  String get scheme => 's3';

  @override
  Capability get caps => const Capability(space: false, checksum: true);

  @override
  ResumeSupport get resume => ResumeSupport.download;

  @override
  Future<int> sizeOf(String path) async {
    try {
      final res = await _send<dynamic>('HEAD', _requestPath(_key(path)));
      return int.tryParse(res.headers.value('content-length') ?? '') ?? -1;
    } catch (_) {
      return -1;
    }
  }

  String get _region => mount.region.trim().isEmpty ? 'us-east-1' : mount.region.trim();

  bool get _isIpHost => InternetAddress.tryParse(_host) != null;

  bool get _pathStyle => mount.bucket.isEmpty || mount.pathStyle || _isIpHost;

  String get _rootPrefix => mount.rootPath.trim().replaceAll(RegExp(r'^/+|/+$'), '');

  @override
  Future<void> connect() async {
    var host = mount.host.trim();
    if (host.isEmpty) throw DriverException('请填写 Endpoint', kind: DriverErrorKind.unknown);
    if (!host.contains('://')) host = 'https://$host';
    final uri = Uri.parse(host);
    _scheme = uri.scheme;
    _host = uri.host;
    _port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 120),
      validateStatus: (s) => s != null && s < 500,
    ));
    _dio.httpClientAdapter = IOHttpClientAdapter(createHttpClient: () => buildHttpClient(proxy));
  }

  @override
  Future<void> close() async => _dio.close(force: true);

  // ---------- 路径 ----------

  String _key(String path) {
    final p = normalizePath(path);
    final rel = p == '/' ? '' : p.substring(1);
    return [_rootPrefix, rel].where((s) => s.isNotEmpty).join('/');
  }

  String _hostHeader() {
    final defaultPort = _scheme == 'https' ? 443 : 80;
    final h = _pathStyle ? _host : '${mount.bucket}.$_host';
    return _port == defaultPort ? h : '$h:$_port';
  }

  String _requestPath(String key, {bool dir = false}) {
    final encodedKey = key.isEmpty ? '' : key.split('/').map(_uriEncode).join('/');
    final withSlash =
        dir && encodedKey.isNotEmpty && !encodedKey.endsWith('/') ? '$encodedKey/' : encodedKey;
    final bucketPart = _pathStyle ? '/${_uriEncode(mount.bucket)}' : '';
    if (withSlash.isEmpty) return bucketPart.isEmpty ? '/' : '$bucketPart/';
    return '$bucketPart/$withSlash';
  }

  String _url(String requestPath, String canonicalQuery) {
    final host = _pathStyle ? _host : '${mount.bucket}.$_host';
    final defaultPort = _scheme == 'https' ? 443 : 80;
    final portPart = _port == defaultPort ? '' : ':$_port';
    return '$_scheme://$host$portPart$requestPath'
        '${canonicalQuery.isEmpty ? '' : '?$canonicalQuery'}';
  }

  static String _uriEncode(String input) {
    final bytes = utf8.encode(input);
    final sb = StringBuffer();
    for (final b in bytes) {
      final ok = (b >= 65 && b <= 90) ||
          (b >= 97 && b <= 122) ||
          (b >= 48 && b <= 57) ||
          b == 0x2D ||
          b == 0x2E ||
          b == 0x5F ||
          b == 0x7E;
      if (ok) {
        sb.writeCharCode(b);
      } else {
        sb.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return sb.toString();
  }

  static String _hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static List<int> _hmac(List<int> key, List<int> data) => Hmac(sha256, key).convert(data).bytes;

  // ---------- 请求 ----------

  Future<Response<T>> _send<T>(
    String method,
    String path, {
    Map<String, String>? query,
    dynamic body,
    Map<String, String>? signHeaders,
    ResponseType? responseType,
    ProgressFn? onProgress,
    int? contentLength,
  }) async {
    final now = DateTime.now().toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    final amzDate = '${now.year.toString().padLeft(4, '0')}${two(now.month)}${two(now.day)}'
        'T${two(now.hour)}${two(now.minute)}${two(now.second)}Z';
    final dateStamp = amzDate.substring(0, 8);

    final qp = <MapEntry<String, String>>[];
    (query ?? const <String, String>{}).forEach((k, v) {
      qp.add(MapEntry(_uriEncode(k), _uriEncode(v)));
    });
    qp.sort((a, b) => a.key == b.key ? a.value.compareTo(b.value) : a.key.compareTo(b.key));
    final canonicalQuery = qp.map((e) => '${e.key}=${e.value}').join('&');

    // SigV4 的 payload hash 必须与真实字节一致：明文 HTTP 下 AWS 不接受
    // UNSIGNED-PAYLOAD，所以统一对 body 求 sha256（分片只有 8 MB，开销可忽略）。
    final payload = _payloadBytes(body);
    final payloadHash = payload == null ? _emptyHash : _hex(sha256.convert(payload).bytes);

    final signed = <String, String>{
      'host': _hostHeader(),
      'x-amz-content-sha256': payloadHash,
      'x-amz-date': amzDate,
      ...?signHeaders,
    };
    final names = signed.keys.toList()..sort();
    final canonicalHeaders = names.map((k) => '$k:${signed[k]!.trim()}\n').join();
    final signedHeaderNames = names.join(';');

    final canonicalRequest =
        '$method\n$path\n$canonicalQuery\n$canonicalHeaders\n$signedHeaderNames\n$payloadHash';
    final scope = '$dateStamp/$_region/s3/aws4_request';
    final stringToSign =
        'AWS4-HMAC-SHA256\n$amzDate\n$scope\n${_hex(sha256.convert(utf8.encode(canonicalRequest)).bytes)}';
    final signingKey = _hmac(
      _hmac(
        _hmac(_hmac(utf8.encode('AWS4$secretKey'), utf8.encode(dateStamp)), utf8.encode(_region)),
        utf8.encode('s3'),
      ),
      utf8.encode('aws4_request'),
    );
    final signature = _hex(_hmac(signingKey, utf8.encode(stringToSign)));

    final headers = <String, String>{
      'x-amz-date': amzDate,
      'x-amz-content-sha256': payloadHash,
      'Authorization':
          'AWS4-HMAC-SHA256 Credential=$accessKey/$scope, SignedHeaders=$signedHeaderNames, Signature=$signature',
      ...?signHeaders,
    };
    if (contentLength != null) headers['Content-Length'] = '$contentLength';

    final cb = onProgress;
    final res = await _dio.fetch<T>(RequestOptions(
      path: _url(path, canonicalQuery),
      method: method,
      headers: headers,
      data: body,
      responseType: responseType ?? ResponseType.plain,
      validateStatus: (s) => s != null && s < 500,
      onSendProgress: cb == null || contentLength == null
          ? null
          : (int sent, int _) {
              cb(sent, contentLength);
            },
    ));
    _check(res, method);
    return res;
  }

  /// 参与签名的原始字节（null 表示空 body）。
  static List<int>? _payloadBytes(dynamic body) {
    if (body == null) return null;
    if (body is Uint8List) return body;
    if (body is List<int>) return body;
    if (body is String) return utf8.encode(body);
    return null;
  }

  static String _bodyText(Response<dynamic> res) {
    final data = res.data;
    if (data is String) return data;
    if (data is List<int>) return utf8.decode(data, allowMalformed: true);
    return '';
  }

  String? _firstText(XmlElement e, String name) {
    for (final c in e.findAllElements(name)) {
      return c.innerText;
    }
    return null;
  }

  void _check(Response<dynamic> res, String action) {
    final code = res.statusCode ?? 0;
    if (code >= 200 && code < 300) return;
    var detail = '';
    try {
      final data = res.data;
      final text = data is String ? data : (data is List<int> ? utf8.decode(data) : '');
      if (text.contains('<Code>')) {
        final doc = XmlDocument.parse(text);
        final el = _firstText(doc.rootElement, 'Code');
        if (el != null) detail = ' · $el';
      }
    } catch (_) {}
    switch (code) {
      case 401:
      case 403:
        throw DriverException('凭据被拒绝或签名不匹配（403$detail）', kind: DriverErrorKind.auth);
      case 404:
        throw DriverException('对象或桶不存在（404$detail）', kind: DriverErrorKind.notFound);
      case 301:
        throw DriverException('区域不匹配（301），请检查 Region', kind: DriverErrorKind.network);
      default:
        throw DriverException('$action 失败（HTTP $code$detail）');
    }
  }

  // ---------- 操作 ----------

  @override
  Future<List<RemoteEntry>> list(String path) async {
    final prefix = _key(path);
    final dirPrefix = prefix.isEmpty ? '' : '$prefix/';
    final res = await _send<dynamic>(
      'GET',
      _requestPath(''),
      query: {'list-type': '2', 'prefix': dirPrefix, 'delimiter': '/', 'max-keys': '1000'},
    );
    final text = res.data is String ? res.data as String : utf8.decode(res.data as List<int>);
    final doc = XmlDocument.parse(text);
    final entries = <RemoteEntry>[];

    for (final node in doc.findAllElements('CommonPrefixes')) {
      final p = _firstText(node, 'Prefix') ?? '';
      if (p.length <= dirPrefix.length) continue;
      final name = p.substring(dirPrefix.length).replaceAll('/', '');
      if (name.isEmpty) continue;
      entries.add(RemoteEntry(name: name, path: joinPath(normalizePath(path), name), isDir: true));
    }
    for (final node in doc.findAllElements('Contents')) {
      final key = _firstText(node, 'Key') ?? '';
      if (key.isEmpty || key == dirPrefix) continue;
      final name = key.substring(dirPrefix.length);
      if (name.contains('/')) continue;
      final size = int.tryParse(_firstText(node, 'Size') ?? '') ?? 0;
      final lm = _firstText(node, 'LastModified');
      entries.add(RemoteEntry(
        name: name,
        path: joinPath(normalizePath(path), name),
        isDir: false,
        size: size,
        modified: lm == null ? null : DateTime.tryParse(lm),
      ));
    }
    entries.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  @override
  Future<SpaceInfo?> space() async => null;

  @override
  Future<Uint8List> readAll(String path) async {
    final res =
        await _send<List<int>>('GET', _requestPath(_key(path)), responseType: ResponseType.bytes);
    return Uint8List.fromList(res.data ?? const []);
  }

  @override
  Future<void> downloadTo(String remotePath, String localFile,
      {ProgressFn? onProgress, int resumeFrom = 0}) async {
    final res = await _send<ResponseBody>(
      'GET',
      _requestPath(_key(remotePath)),
      responseType: ResponseType.stream,
      // Range 参与 SigV4 签名，必须走 signed headers。
      signHeaders: resumeFrom > 0 ? {'range': 'bytes=$resumeFrom-'} : null,
    );
    final body = res.data;
    if (body == null) throw DriverException('响应为空', kind: DriverErrorKind.network);
    final partial = resumeFrom > 0 && res.statusCode == 206;
    final remain = int.tryParse(res.headers.value('content-length') ?? '') ?? 0;
    final total = partial ? resumeFrom + remain : remain;
    final sink =
        File(localFile).openWrite(mode: partial ? FileMode.append : FileMode.write);
    var done = partial ? resumeFrom : 0;
    try {
      await for (final chunk in body.stream) {
        sink.add(chunk);
        done += chunk.length;
        onProgress?.call(done, total);
      }
    } finally {
      await sink.close();
    }
  }

  /// 分片上传：> 8 MB 走 multipart，取消/失败都会 Abort，避免留下垃圾分片。
  static const _defaultPart = 8 * 1024 * 1024;

  @override
  Future<void> uploadFile(String localFile, String remotePath,
      {ProgressFn? onProgress, int resumeFrom = 0}) async {
    // 分片上传的续传需要持久化 uploadId 与已传分片，本版不做：一律整份重传。
    final file = File(localFile);
    final length = await file.length();
    final key = _key(remotePath);
    final partSize = _choosePartSize(length);

    if (length <= partSize) {
      final bytes = await file.readAsBytes();
      await _send<dynamic>(
        'PUT',
        _requestPath(key),
        body: bytes,
        contentLength: length,
        onProgress: onProgress,
      );
      onProgress?.call(length, length);
      return;
    }
    await _multipartUpload(file, key, length, partSize, onProgress);
  }

  /// 控制分片数在 900 以内（协议上限 10000，留足余量给小文件抖动）。
  int _choosePartSize(int length) {
    var size = _defaultPart;
    while (length > size * 900) {
      size *= 2;
    }
    return size;
  }

  Future<void> _multipartUpload(
    File file,
    String key,
    int length,
    int partSize,
    ProgressFn? onProgress,
  ) async {
    final init = await _send<dynamic>('POST', _requestPath(key), query: {'uploads': ''});
    String? uploadId;
    try {
      uploadId = _firstText(XmlDocument.parse(_bodyText(init)).rootElement, 'UploadId');
    } catch (_) {}
    if (uploadId == null || uploadId.isEmpty) {
      throw DriverException('初始化分片上传失败：响应里没有 UploadId', kind: DriverErrorKind.unknown);
    }

    final etags = <String>[];
    final raf = await file.open();
    try {
      var offset = 0;
      var partNumber = 1;
      while (offset < length) {
        final remain = length - offset;
        final chunkLen = remain < partSize ? remain : partSize;
        final chunk = await raf.read(chunkLen);
        if (chunk.isEmpty) break;
        final res = await _send<dynamic>(
          'PUT',
          _requestPath(key),
          query: {'partNumber': '$partNumber', 'uploadId': uploadId},
          body: chunk,
          contentLength: chunk.length,
          onProgress: onProgress == null
              ? null
              : (int sent, int _) => onProgress(offset + sent, length),
        );
        final etag = res.headers.value('etag');
        if (etag == null || etag.isEmpty) {
          throw DriverException('第 $partNumber 片没有返回 ETag', kind: DriverErrorKind.unknown);
        }
        etags.add(etag);
        offset += chunk.length;
        partNumber++;
        onProgress?.call(offset, length);
      }
    } catch (e) {
      // 任何中断（含用户暂停）都清理未完成的分片上传
      try {
        await _send<dynamic>('DELETE', _requestPath(key), query: {'uploadId': uploadId});
      } catch (_) {}
      rethrow;
    } finally {
      await raf.close();
    }

    final sb = StringBuffer('<CompleteMultipartUpload>');
    for (var i = 0; i < etags.length; i++) {
      sb.write('<Part><PartNumber>${i + 1}</PartNumber><ETag>${etags[i]}</ETag></Part>');
    }
    sb.write('</CompleteMultipartUpload>');
    final body = sb.toString();
    await _send<dynamic>(
      'POST',
      _requestPath(key),
      query: {'uploadId': uploadId},
      body: body,
      contentLength: utf8.encode(body).length,
    );
  }

  @override
  Future<void> mkdir(String path) async {
    final key = _key(path);
    if (key.isEmpty) return;
    await _send<dynamic>('PUT', _requestPath(key, dir: true),
        body: Uint8List(0), contentLength: 0);
  }

  @override
  Future<void> removeEntry(RemoteEntry entry) async {
    if (!entry.isDir) {
      await _send<dynamic>('DELETE', _requestPath(_key(entry.path)));
      return;
    }
    // 目录删除必须分页：单次 ListObjectsV2 最多 1000 个键，大目录会漏删。
    final prefix = _key(entry.path);
    String? token;
    while (true) {
      final query = <String, String>{
        'list-type': '2',
        'prefix': '$prefix/',
        'max-keys': '1000',
        if (token != null) 'continuation-token': token,
      };
      final res = await _send<dynamic>('GET', _requestPath(''), query: query);
      final doc = XmlDocument.parse(_bodyText(res));
      for (final node in doc.findAllElements('Contents')) {
        final key = _firstText(node, 'Key') ?? '';
        if (key.isEmpty) continue;
        await _send<dynamic>('DELETE', _requestPath(key));
      }
      final truncated =
          (_firstText(doc.rootElement, 'IsTruncated') ?? '').toLowerCase() == 'true';
      if (!truncated) break;
      token = _firstText(doc.rootElement, 'NextContinuationToken');
      if (token == null || token.isEmpty) break;
    }
  }

  @override
  Future<void> move(String from, String to) async {
    final srcKey = _key(from);
    final dstKey = _key(to);
    if (srcKey.isEmpty) throw DriverException('不能移动挂载根目录', kind: DriverErrorKind.unsupported);
    final copySource = '/${mount.bucket}/${srcKey.split('/').map(_uriEncode).join('/')}';
    await _send<dynamic>(
      'PUT',
      _requestPath(dstKey),
      body: Uint8List(0),
      contentLength: 0,
      signHeaders: {'x-amz-copy-source': copySource},
    );
    await _send<dynamic>('DELETE', _requestPath(srcKey));
  }

  @override
  Future<int> probe() async {
    final items = await list('/');
    return items.length;
  }
}
