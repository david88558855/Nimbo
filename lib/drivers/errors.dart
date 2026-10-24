import 'storage_driver.dart';

/// 把驱动异常翻译成「发生了什么 + 下一步能做什么」。
///
/// 只做措辞，不改变原有信息：`DriverException.message` 仍然是排查的主线索
/// （里面通常带着 HTTP 码 / FTP 回复码 / 服务器原文），这里只是按
/// [DriverErrorKind] 追一句可执行的建议，避免界面上只有一句「失败」。
String describeError(Object error) {
  if (error is DriverException) {
    return '${error.message}${_advice(error.kind)}';
  }
  final text = '$error';
  return text.trim().isEmpty ? '未知错误' : text;
}

String _advice(DriverErrorKind kind) => switch (kind) {
      DriverErrorKind.auth => '（检查用户名与密码；S3 还要确认 Access Key / Secret Key / Region）',
      DriverErrorKind.notFound => '（路径不存在，可能已被移动或删除；可刷新后重试）',
      DriverErrorKind.permission => '（账号对该路径没有权限，或挂载被设为只读）',
      DriverErrorKind.network => '（检查主机与端口是否可达；内网地址请确认当前网络环境）',
      DriverErrorKind.proxy => '（先确认代理本身可用，再核对代理类型与账号密码）',
      DriverErrorKind.unsupported => '（当前协议不支持该操作，可改用下载后上传）',
      DriverErrorKind.unknown => '',
    };

/// 传输队列里的错误只需要一行：折行会把卡片撑开。
String shortError(Object error) {
  final text = describeError(error);
  return text.length > 200 ? '${text.substring(0, 200)}…' : text;
}
