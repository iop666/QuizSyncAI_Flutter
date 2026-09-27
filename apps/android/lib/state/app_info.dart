/// 应用身份常量（安卓端）。
///
/// 与 `apps/android/pubspec.yaml` 的 `version:` 保持一致。
///
/// **界面上一律只显示版本号**，不出现「（构建 N）」。
/// 出包序号（pubspec 的 `1.1.0+N`）只用来保证 `versionCode` 只增不减、
/// 新包能覆盖安装，不进任何界面文案。
///
/// 双端统一到 **1.1.0**（安卓端从 1.0.0 升上来）。
library;

const String kAppName = 'AI 双端搜题';

/// 项目名（GitHub 仓库名与包名保持英文）。
const String kAppNameEn = 'QuizSync AI';

/// 项目地址（关于页要标明）。
const String kGitHubUrl = 'https://github.com/iop666/QuizSyncAI';

const String kAppVersion = '1.1.0';
