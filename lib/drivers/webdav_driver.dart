import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:xml/xml.dart';

import '../core/format.dart';
import '../core/limiter.dart';
import '../core/models.dart';
import '../core/upload_checkpoint.dart';
import 'net.dart';
import 'storage_driver.dart';

/// WebDAV：PROPFIND 列目录、GET/PUT 读写、MKCOL/MOVE/DELETE 管理。
/// 不依赖第三方 WebDAV 包，方便统一在 HTTP 层挂代理。
class WebDavDriver extends StorageDriver {
  WebDavDriver(super.mount, {required this.password, required this.proxy});

  final String password;
  final ProxyConfig proxy;
  late final Dio _dio;
  late final String _base;

  @override
  String get scheme => 'dav';

  @override
  Capability get caps => const Capability(space: true);

  /// 下载靠 Range 续传；上传靠 `PUT` + `Content-Range` 续写。
  /// 上传的续传是**探测式**的：服务器不支持部分写入时会静默退回整份重传
  /// （见 [_putRange]），所以这个能力位不保证「一定能续」。
  @override
  ResumeSupport get resume => ResumeSupport.both;

  /// 上传中途用的临时名后缀。续传依赖它：远端这个文件的实际长度就是续传起点。
  static const String _tempSuffix = '.nimbo-part';

  /// 大小：优先 HEAD（有的服务器把 HEAD 直接 405），失败回落 PROPFIND Depth:0。
  @override
  Future<int> sizeOf(String path) async {
    try {
      final res = await _dio.head<dynamic>(_uri(path).toString());
      final len = int.tryParse(res.headers.value('content-length') ?? '');
      if (res.statusCode != null && res.statusCode! < 300 && len != null) return len;
    } catch (_) {}
    try {
      final res = await _dio.request<dynamic>(
        _uri(path).toString(),
        data: _propfindBody,
        options: Options(
          method: 'PROPFIND',
          headers: {'Depth': '0', 'Content-Type': 'application/xml; charset=utf-8'},
          responseType: ResponseType.plain,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      if ((res.statusCode ?? 0) >= 300) return -1;
      final raw = res.data;
      final text = raw is String ? raw : utf8.decode(raw as List<int>, allowMalformed: true);
      for (final el in XmlDocument.parse(text).descendants.whereType<XmlElement>()) {
        if (el.localName == 'getcontentlength') {
          return int.tryParse(el.innerText.trim()) ?? -1;
        }
      }
    } catch (_) {}
    return -1;
  }

  String get _rootPath {
    final p = mount.rootPath.trim();
    if (p.isEmpty || p == '/') return '';
    final withSlash = p.startsWith('/') ? p : '/$p';
    return withSlash.replaceAll(RegExp(r'/+$'), '');
  }

  @override
  Future<void> connect() async {
    var host = mount.host.trim();
    if (host.isEmpty) throw DriverException('请填写服务器地址', kind: DriverErrorKind.unknown);
    if (!host.startsWith('http://') && !host.startsWith('https://')) {
      host = 'https://$host';
    }
    final baseUri = Uri.parse(host);
    final port = mount.port;
    final needPort = port != 0 &&
        port != 80 &&
        port != 443 &&
        !baseUri.hasPort;
    final authority = needPort
        ? '${baseUri.scheme}://${baseUri.host}:$port'
        : '${baseUri.scheme}://${baseUri.host}${baseUri.hasPort ? ':${baseUri.port}' : ''}';
    // 服务器地址里带路径（https://host/dav）时不能丢：丢了会连到服务器根，
    // 表现为「同一个地址别的客户端能进、本应用 404」。
    final basePath = baseUri.path.replaceAll(RegExp(r'/+$'), '');
    _base = '$authority$basePath';

    final headers = <String, String>{'User-Agent': 'Nimbo/0.1'};
    if (mount.username.isNotEmpty) {
      headers['Authorization'] =
          'Basic ${base64Encode(utf8.encode('${mount.username}:$password'))}';
    }
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 60),
      sendTimeout: const Duration(seconds: 60),
      headers: headers,
      validateStatus: (s) => s != null && s < 500,
    ));
    _dio.httpClientAdapter = IOHttpClientAdapter(createHttpClient: () => buildHttpClient(proxy));
  }

  @override
  Future<void> close() async {
    _dio.close(force: true);
  }

  String _encodePath(String path) {
    final p = normalizePath(path);
    return p.split('/').map((s) => s.isEmpty ? '' : Uri.encodeComponent(s)).join('/');
  }

  Uri _uri(String path, {bool dir = false}) {
    var p = '$_base$_rootPath${_encodePath(path)}';
    if (dir && !p.endsWith('/')) p = '$p/';
    return Uri.parse(p);
  }

  void _check(Response<dynamic> res, String action) {
    final code = res.statusCode ?? 0;
    if (code >= 200 && code < 300) return;
    if (code == 401 || code == 403) {
      throw DriverException('凭据被拒绝或无权访问（$code）', kind: DriverErrorKind.auth);
    }
    if (code == 404) throw DriverException('路径不存在（404）', kind: DriverErrorKind.notFound);
    throw DriverException('$action 失败（HTTP $code）', kind: DriverErrorKind.unknown);
  }

  static const _propfindBody = '<?xml version="1.0" encoding="utf-8" ?>'
      '<d:propfind xmlns:d="DAV:"><d:prop>'
      '<d:displayname/><d:getcontentlength/><d:getlastmodified/><d:resourcetype/>'
      '</d:prop></d:propfind>';

  @override
  Future<List<RemoteEntry>> list(String path) async {
    final url = _uri(path, dir: true);
    // 必须用 _dio.request 而不是 _dio.fetch(RequestOptions)：后者不合并
    // BaseOptions.headers，Authorization 会丢，服务器一律回 401。
    final res = await _dio.request<dynamic>(
      url.toString(),
      data: _propfindBody,
      options: Options(
        method: 'PROPFIND',
        headers: {'Depth': '1', 'Content-Type': 'application/xml; charset=utf-8'},
        responseType: ResponseType.plain,
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    _check(res, '列目录');

    final raw = res.data;
    final text = raw is String ? raw : utf8.decode(raw as List<int>, allowMalformed: true);
    final doc = XmlDocument.parse(text);

    final requestPath = Uri.decodeFull(url.path);
    final entries = <RemoteEntry>[];
    for (final el in doc.descendants.whereType<XmlElement>()) {
      if (el.localName != 'response') continue;
      String? href;
      var isDir = false;
      var size = 0;
      DateTime? modified;
      for (final child in el.descendants.whereType<XmlElement>()) {
        switch (child.localName) {
          case 'href':
            href ??= child.innerText.trim();
            break;
          case 'collection':
            isDir = true;
            break;
          case 'getcontentlength':
            size = int.tryParse(child.innerText.trim()) ?? 0;
            break;
          case 'getlastmodified':
            try {
              modified = HttpDate.parse(child.innerText.trim());
            } catch (_) {}
            break;
        }
      }
      if (href == null || href.isEmpty) continue;
      final hrefPath = Uri.decodeFull(Uri.parse(href).path);
      if (normalizePath(hrefPath) == normalizePath(requestPath)) continue;
      final segments = splitPath(hrefPath);
      if (segments.isEmpty) continue;
      final name = segments.last;
      entries.add(RemoteEntry(
        name: name,
        path: joinPath(normalizePath(path), name),
        isDir: isDir,
        size: isDir ? 0 : size,
        modified: modified,
      ));
    }
    entries.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  @override
  Future<SpaceInfo?> space() async {
    try {
      final url = _uri('/', dir: true);
      final res = await _dio.request<dynamic>(
        url.toString(),
        data: '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop>'
            '<d:quota-available-bytes/><d:quota-used-bytes/></d:prop></d:propfind>',
        options: Options(
          method: 'PROPFIND',
          headers: {'Depth': '0', 'Content-Type': 'application/xml; charset=utf-8'},
          responseType: ResponseType.plain,
        ),
      );
      final text = res.data is String ? res.data as String : '';
      final doc = XmlDocument.parse(text);
      int? total;
      int? free;
      for (final el in doc.descendants.whereType<XmlElement>()) {
        if (el.localName == 'quota-available-bytes') free = int.tryParse(el.innerText.trim());
        if (el.localName == 'quota-used-bytes') total = int.tryParse(el.innerText.trim());
      }
      if (total == null || free == null) return null;
      return SpaceInfo(total + free, free);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Uint8List> readAll(String path) async {
    final res = await _dio.get<List<int>>(
      _uri(path).toString(),
      options: Options(responseType: ResponseType.bytes),
    );
    _check(res, '下载');
    return Uint8List.fromList(res.data ?? const []);
  }

  @override
  Future<void> downloadTo(String remotePath, String localFile,
      {ProgressFn? onProgress, int resumeFrom = 0}) async {
    final res = await _dio.get<ResponseBody>(
      _uri(remotePath).toString(),
      options: Options(
        responseType: ResponseType.stream,
        headers: {if (resumeFrom > 0) 'Range': 'bytes=$resumeFrom-'},
      ),
    );
    _check(res, '下载');
    final body = res.data;
    if (body == null) throw DriverException('响应为空', kind: DriverErrorKind.network);
    // 只有真正拿到 206 才能续写；服务器忽略 Range 返回 200 时必须从头覆盖。
    final partial = resumeFrom > 0 && res.statusCode == 206;
    final remain = int.tryParse(res.headers.value('content-length') ?? '') ?? 0;
    final total = partial ? resumeFrom + remain : remain;
    final sink =
        File(localFile).openWrite(mode: partial ? FileMode.append : FileMode.write);
    var done = partial ? resumeFrom : 0;
    try {
      await for (final chunk in body.stream) {
        await TransferLimiter.instance.download.take(chunk.length);
        sink.add(chunk);
        done += chunk.length;
        onProgress?.call(done, total);
      }
    } finally {
      await sink.close();
    }
  }

  /// 上传：先写临时名，成功后再 MOVE 成正式名。
  ///
  /// WebDAV 既没有标准的追加写，也不保证「PUT 到一半中断」会回滚，直接写正式名
  /// 会留下看起来正常、其实缺尾部的文件（比失败更糟）。写临时名后 MOVE 是
  /// 原子的，中断时正式路径上要么是旧文件，要么什么也没有。
  /// 代价：同目录下会短暂出现 `*.nimbo-part`，异常退出时可能残留（下次同名上传会续传/覆盖）。
  @override
  Future<void> uploadFile(String localFile, String remotePath,
      {ProgressFn? onProgress, int resumeFrom = 0}) async {
    final file = File(localFile);
    final stat = await file.stat();
    final length = stat.size;
    final mtime = stat.modified.millisecondsSinceEpoch;
    final tempPath = '$remotePath$_tempSuffix';

    // 先看看这个路径上一次的记录是否属于「同一个文件」（大小 + 修改时间）。
    // 只有它匹配，才敢拿远端那个临时文件的前缀继续写。
    final prior = await UploadCheckpointStore.load(mount.id, remotePath, length);
    final sameFile = prior != null && prior.matches(length, mtime);

    // 登记本次上传的指纹（后续续传靠它判断是不是同一个文件）。
    await UploadCheckpointStore.save(
      mount.id,
      remotePath,
      UploadCheckpoint(
        length: length,
        mtimeMs: mtime,
        offset: prior != null && sameFile ? prior.offset : 0,
      ),
    );

    // 续传起点一律实测：远端临时文件有多少字节，就从那里接着写。
    var start = (resumeFrom > 0 && sameFile)
        ? await uploadResumeOffset(localFile, remotePath, resumeFrom)
        : 0;

    if (start == 0 && sameFile && length > 0) {
      // 临时文件已经完整（上次卡在 MOVE，或断开在最后一块）：不必重传。
      final existing = await sizeOf(tempPath);
      if (existing == length) {
        await _moveTempToFinal(tempPath, remotePath);
        await UploadCheckpointStore.remove(mount.id, remotePath);
        onProgress?.call(length, length);
        return;
      }
    }

    if (start > 0) {
      final ok = await _putRange(file, tempPath, start, length, onProgress);
      if (ok) {
        await UploadCheckpointStore.save(
          mount.id,
          remotePath,
          UploadCheckpoint(length: length, mtimeMs: mtime, offset: length),
        );
        await _moveTempToFinal(tempPath, remotePath);
        await UploadCheckpointStore.remove(mount.id, remotePath);
        return;
      }
      // 服务器不支持部分写入（或写了但总长度不对）：降级为整份重传。
      // 临时文件会被下面的 PUT 覆盖写，不会拼出错位内容。
      start = 0;
    }

    await _putWhole(file, tempPath, length, onProgress);
    await _moveTempToFinal(tempPath, remotePath);
    await UploadCheckpointStore.remove(mount.id, remotePath);
  }

  /// 上传续传起点：只在「同一个文件 + 远端临时文件确实有半截」时才续。
  @override
  Future<int> uploadResumeOffset(
    String localFile,
    String remotePath,
    int resumeFrom,
  ) async {
    if (resumeFrom <= 0) return 0;
    try {
      final stat = await File(localFile).stat();
      final local = stat.size;
      if (local <= 0) return 0;
      // 没有检查点 / 指纹不符：不认这个断点（避免拿别的文件的前缀来拼）。
      final cp = await UploadCheckpointStore.load(mount.id, remotePath, local);
      if (cp == null || !cp.matches(local, stat.modified.millisecondsSinceEpoch)) {
        return 0;
      }
      final remote = await sizeOf('$remotePath$_tempSuffix');
      if (remote <= 0 || remote >= local) return 0;
      return remote;
    } catch (_) {
      return 0;
    }
  }

  /// 整份上传到临时名（覆盖写，幂等）。
  Future<void> _putWhole(
    File file,
    String tempPath,
    int length,
    ProgressFn? onProgress,
  ) async {
    final res = await _dio.put<dynamic>(
      _uri(tempPath).toString(),
      data: throttleStream(file.openRead(), TransferLimiter.instance.upload),
      options: Options(
        headers: {'Content-Length': length, 'Content-Type': 'application/octet-stream'},
      ),
      onSendProgress: onProgress == null ? null : (sent, total) => onProgress(sent, length),
    );
    _check(res, '上传');
  }

  /// 从 [start] 续写剩余字节：`PUT` + `Content-Range`（RFC 7231 的 partial PUT）。
  ///
  /// 返回 false 表示「这台服务器不支持部分写入」，调用方应整份重传。
  /// 判定分两层，缺一不可：
  /// - 明确的拒绝码（400/405/409/415/416/501）；
  /// - **写完校验总长度**：有些服务器不报错、直接把这半段当成整份写进去，
  ///   只看状态码会得到一个「长度不对但看起来成功」的文件。
  Future<bool> _putRange(
    File file,
    String tempPath,
    int start,
    int length,
    ProgressFn? onProgress,
  ) async {
    // 这里**不**捕获网络异常：抖动/中断要一路抛上去（任务转失败或暂停，
    // 临时文件与断点留着），不能误判成「服务器不支持部分写入」而白传一遍。
    final res = await _dio.put<dynamic>(
      _uri(tempPath).toString(),
      data: throttleStream(
        file.openRead(start),
        TransferLimiter.instance.upload,
      ),
      options: Options(
        headers: {
          'Content-Length': length - start,
          'Content-Range': 'bytes $start-${length - 1}/$length',
          'Content-Type': 'application/octet-stream',
        },
      ),
      onSendProgress:
          onProgress == null ? null : (sent, total) => onProgress(start + sent, length),
    );
    final code = res.statusCode ?? 0;
    if (code == 400 || code == 405 || code == 409 || code == 415 || code == 416 || code == 501) {
      return false;
    }
    if (code < 200 || code >= 300) _check(res, '续传上传');
    // 部分写入没法靠状态码确认，只能量长度。
    final size = await sizeOf(tempPath);
    return size == length;
  }

  Future<void> _moveTempToFinal(String tempPath, String remotePath) async {
    final moved = await _dio.request<dynamic>(
      _uri(tempPath).toString(),
      options: Options(
        method: 'MOVE',
        headers: {'Destination': _uri(remotePath).toString(), 'Overwrite': 'T'},
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    _check(moved, '重命名上传结果');
  }

  @override
  Future<void> mkdir(String path) async {
    final res = await _dio.request<dynamic>(
      _uri(path, dir: true).toString(),
      options: Options(
        method: 'MKCOL',
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    final code = res.statusCode ?? 0;
    if (code == 405) return; // 已存在
    _check(res, '新建目录');
  }

  @override
  Future<void> removeEntry(RemoteEntry entry) async {
    final res = await _dio.delete<dynamic>(
      _uri(entry.path, dir: entry.isDir).toString(),
      options: Options(validateStatus: (s) => s != null && s < 500),
    );
    _check(res, '删除');
  }

  @override
  Future<void> move(String from, String to) async {
    final res = await _dio.request<dynamic>(
      _uri(from).toString(),
      options: Options(
        method: 'MOVE',
        headers: {'Destination': _uri(to).toString(), 'Overwrite': 'T'},
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    _check(res, '移动');
  }

  @override
  Future<int> probe() async {
    final items = await list('/');
    return items.length;
  }
}
