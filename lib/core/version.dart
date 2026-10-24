/// 版本号的**唯一来源**。
///
/// 界面里原来有两处硬编码（侧栏 `0.1`、设置页 `0.2.0 (P1 传输闭环)`），
/// 发版时容易漏改。这里集中一份，改版本时同时改 `pubspec.yaml` 的 `version:`。
const String kAppVersion = '0.4.0';
const int kAppBuild = 4;

/// 界面展示用：`0.4.0+4`。
const String kAppVersionLabel = '$kAppVersion+$kAppBuild';
