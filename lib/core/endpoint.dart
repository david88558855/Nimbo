/// S3 / WebDAV 这类「端口写在地址里」的服务器地址，统一在这里解析。
///
/// 为什么要有这一层：S3 与 WebDAV 都跑在 HTTP 之上，端口本身就是 URL 的一部分。
/// 表单再给一个独立端口输入框，会出现「地址里写了 :8443、端口框里写 443」这种自相
/// 矛盾的配置，也让保存后的 mount.port 变成无意义的残留字段。所以：
/// - 表单对这两个协议不再提供端口输入框；
/// - 地址的解析（协议、主机、端口、基础路径）统一走 [parseEndpoint]，
///   驱动与表单用同一套规则，避免「界面看着对、连的时候不对」。
class HostEndpoint {
  const HostEndpoint({
    required this.scheme,
    required this.host,
    required this.port,
    required this.explicitPort,
    this.basePath = '',
  });

  /// `http` / `https`（小写）。
  final String scheme;

  /// 主机名或 IP，不含端口。
  final String host;

  /// 实际连接端口：地址里写了就用地址里的，否则按协议默认（https 443 / http 80）。
  final int port;

  /// 地址里（或调用方给的兜底端口）是否显式指定了端口。
  final bool explicitPort;

  /// 地址里的路径部分，已去掉结尾斜杠；`''` 表示服务器根。
  final String basePath;

  String get authority => explicitPort ? '$host:$port' : host;

  /// `scheme://host[:port]`，WebDAV 的 base URL 用它。
  String get origin => '$scheme://$authority';

  /// `scheme://host[:port][/basePath]`。
  String get url => '$origin$basePath';

  /// 给界面展示的「解析结果」。
  String get summary =>
      '$origin${basePath.isEmpty ? '' : ' · 基础路径 $basePath'}';

  @override
  String toString() => url;
}

/// 解析服务器地址。
///
/// 规则（S3 与 WebDAV 共用）：
/// - 没写协议时按 [defaultScheme] 补，默认 `https`（这两个协议不该默认明文）；
/// - 端口取地址里的显式端口；没写时优先用 [fallbackPort]（老配置把端口存在独立字段里），
///   再退回协议默认端口；
/// - 地址里带路径（`https://host/dav`）时保留为 [HostEndpoint.basePath]；
/// - 地址为空、没有主机名、端口非法时抛 [FormatException]，由表单给出可读提示。
HostEndpoint parseEndpoint(
  String raw, {
  String defaultScheme = 'https',
  int fallbackPort = 0,
}) {
  var input = raw.trim();
  if (input.isEmpty) {
    throw const FormatException('地址为空，请填写完整地址（含 http:// 或 https://）');
  }
  if (!input.contains('://')) input = '$defaultScheme://$input';

  final Uri uri;
  try {
    uri = Uri.parse(input);
  } on FormatException catch (e) {
    throw FormatException('地址格式不正确：${e.message}');
  }
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    throw FormatException('只支持 http:// 或 https:// 开头的地址（当前是 ${uri.scheme}://）');
  }
  if (uri.host.isEmpty) {
    throw FormatException('地址里没有主机名，例如 https://dav.example.com:8443');
  }

  final int port;
  final bool explicit;
  if (uri.hasPort) {
    // Uri 已过滤掉非数字端口，但越界值（>65535）需要自己拦。
    if (uri.port < 1 || uri.port > 65535) {
      throw FormatException('端口超出范围（1–65535）：${uri.port}');
    }
    port = uri.port;
    explicit = true;
  } else if (fallbackPort > 0) {
    if (fallbackPort > 65535) {
      throw FormatException('端口超出范围（1–65535）：$fallbackPort');
    }
    port = fallbackPort;
    explicit = true;
  } else {
    port = uri.scheme == 'https' ? 443 : 80;
    explicit = false;
  }

  return HostEndpoint(
    scheme: uri.scheme,
    host: uri.host,
    port: port,
    explicitPort: explicit,
    basePath: uri.path.replaceAll(RegExp(r'/+$'), ''),
  );
}
