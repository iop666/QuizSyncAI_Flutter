import 'package:flutter/foundation.dart';

import 'package:quizsync_core/quizsync_core.dart';

/// 两端共享的应用设置（原 desktop state/settings.dart 上移，安卓复用）。

/// 键值存储抽象：真实实现走 DB settings 表；测试用内存实现。
abstract class KeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class MemoryKeyValueStore implements KeyValueStore {
  final Map<String, String> _map = {};
  @override
  Future<String?> read(String key) async => _map[key];
  @override
  Future<void> write(String key, String value) async => _map[key] = value;
}

class DriftKeyValueStore implements KeyValueStore {
  final CoreRepository repo;
  DriftKeyValueStore(this.repo);
  @override
  Future<String?> read(String key) => repo.getSetting(key);
  @override
  Future<void> write(String key, String value) => repo.setSetting(key, value);
}

enum ThemeMode2 { system, light, dark }

/// 应用外观与行为设置（SPEC 2.3 / 4.1 / 4.2）。两端各自独立持久化。
class AppSettings {
  final ThemeMode2 theme;
  final double fontSize; // 12–32，默认 16
  final bool clipboardWatch; // 默认开
  final bool saveImageFiles; // 是否保存图片文件到本地
  final int listenPort; // 默认 8765（M4 生效）

  /// 自定义全局热键（HotKey.toJson）；null = 用默认候选键自动探测。
  /// [hotkeyJson] 是「截图识别」；另外两个槽位各自独立（用户反馈 6：
  /// 热键模块重写后三个用途都能自定义）。键名保持 `hotkey_json` 不变，
  /// 老配置不丢。
  final String? hotkeyJson;
  final String? appendHotkeyJson;
  final String? finishHotkeyJson;

  final int accent; // 主题种子色（ARGB），默认品牌绿 #16A34A

  /// 本地截取图片缓存上限（用户需求 5）：默认 60 张，0 = 不设限。
  final int imageCacheLimit;

  /// 多页识别单次最多页数（用户需求 4）：默认 6，范围 1..12。
  final int multiPageLimit;

  /// 题目正文字重（用户反馈 1）：MiSans 可变字体的 wght 轴，默认 400。
  final int questionFontWeight;

  /// 界面整体缩放（用户反馈 9）：0.5–3.0，默认 1.0。
  final double uiScale;

  /// 安卓「识别模块」（截取图片传主机分析）总开关（用户需求 11）：默认关闭。
  final bool androidRecognitionEnabled;

  /// Windows 悬浮球（用户反馈 11）：开关、大小、透明度、描边。
  final bool ballEnabled;
  final double ballSize;
  final double ballOpacity;
  final bool ballStroke;
  final double ballStrokeWidth;
  final double ballStrokeOpacity;

  const AppSettings({
    this.theme = ThemeMode2.system,
    this.fontSize = 16,
    this.clipboardWatch = true,
    this.saveImageFiles = true,
    this.listenPort = 8765,
    this.hotkeyJson,
    this.appendHotkeyJson,
    this.finishHotkeyJson,
    this.accent = 0xFF16A34A,
    this.imageCacheLimit = kDefaultImageCacheLimit,
    this.multiPageLimit = kDefaultMultiPageLimit,
    this.androidRecognitionEnabled = false,
    this.questionFontWeight = 400,
    this.uiScale = 1.0,
    // 用户反馈 M14 第 4 条：悬浮球默认打开（用户明确要求「默认打开悬浮球」）。
    this.ballEnabled = kDefaultBallEnabled,
    this.ballSize = kDefaultBallSize,
    this.ballOpacity = kDefaultBallOpacity,
    // M17 第 1 条：描边默认打开、宽 4、不透明度 25%。
    this.ballStroke = kDefaultBallStroke,
    this.ballStrokeWidth = kDefaultBallStrokeWidth,
    this.ballStrokeOpacity = kDefaultBallStrokeOpacity,
  });

  AppSettings copyWith({
    ThemeMode2? theme,
    double? fontSize,
    bool? clipboardWatch,
    bool? saveImageFiles,
    int? listenPort,
    String? hotkeyJson,
    bool clearHotkey = false,
    String? appendHotkeyJson,
    bool clearAppendHotkey = false,
    String? finishHotkeyJson,
    bool clearFinishHotkey = false,
    int? accent,
    int? imageCacheLimit,
    int? multiPageLimit,
    bool? androidRecognitionEnabled,
    int? questionFontWeight,
    double? uiScale,
    bool? ballEnabled,
    double? ballSize,
    double? ballOpacity,
    bool? ballStroke,
    double? ballStrokeWidth,
    double? ballStrokeOpacity,
  }) =>
      AppSettings(
        theme: theme ?? this.theme,
        fontSize: (fontSize ?? this.fontSize).clamp(12.0, 32.0),
        clipboardWatch: clipboardWatch ?? this.clipboardWatch,
        saveImageFiles: saveImageFiles ?? this.saveImageFiles,
        listenPort: listenPort ?? this.listenPort,
        hotkeyJson: clearHotkey ? null : (hotkeyJson ?? this.hotkeyJson),
        appendHotkeyJson: clearAppendHotkey
            ? null
            : (appendHotkeyJson ?? this.appendHotkeyJson),
        finishHotkeyJson: clearFinishHotkey
            ? null
            : (finishHotkeyJson ?? this.finishHotkeyJson),
        accent: accent ?? this.accent,
        imageCacheLimit:
            (imageCacheLimit ?? this.imageCacheLimit) < 0 ? 0 : (imageCacheLimit ?? this.imageCacheLimit),
        multiPageLimit:
            (multiPageLimit ?? this.multiPageLimit).clamp(1, kHardMaxPagesPerTask),
        androidRecognitionEnabled:
            androidRecognitionEnabled ?? this.androidRecognitionEnabled,
        questionFontWeight: (questionFontWeight ?? this.questionFontWeight)
            .clamp(kMinQuestionFontWeight, kMaxQuestionFontWeight),
        uiScale: (uiScale ?? this.uiScale).clamp(kMinUiScale, kMaxUiScale),
        ballEnabled: ballEnabled ?? this.ballEnabled,
        ballSize:
            (ballSize ?? this.ballSize).clamp(kMinBallSize, kMaxBallSize),
        ballOpacity: (ballOpacity ?? this.ballOpacity)
            .clamp(kMinBallOpacity, 1.0),
        ballStroke: ballStroke ?? this.ballStroke,
        ballStrokeWidth: (ballStrokeWidth ?? this.ballStrokeWidth)
            .clamp(kMinBallStrokeWidth, kMaxBallStrokeWidth),
        ballStrokeOpacity: (ballStrokeOpacity ?? this.ballStrokeOpacity)
            .clamp(0.0, 1.0),
      );

  Map<String, String> toMap() => {
        'theme': theme.name,
        'font_size': fontSize.toString(),
        'clipboard_watch': clipboardWatch ? '1' : '0',
        'save_image_files': saveImageFiles ? '1' : '0',
        'listen_port': listenPort.toString(),
        'hotkey_json': hotkeyJson ?? '',
        'hotkey_json_append': appendHotkeyJson ?? '',
        'hotkey_json_finish': finishHotkeyJson ?? '',
        'accent': accent.toString(),
        kImageCacheLimitKey: imageCacheLimit.toString(),
        kMultiPageLimitKey: multiPageLimit.toString(),
        kAndroidRecognitionEnabledKey: androidRecognitionEnabled ? '1' : '0',
        kQuestionFontWeightKey: questionFontWeight.toString(),
        kUiScaleKey: uiScale.toString(),
        kBallEnabledKey: ballEnabled ? '1' : '0',
        kBallSizeKey: ballSize.toString(),
        kBallOpacityKey: ballOpacity.toString(),
        kBallStrokeKey: ballStroke ? '1' : '0',
        kBallStrokeWidthKey: ballStrokeWidth.toString(),
        kBallStrokeOpacityKey: ballStrokeOpacity.toString(),
      };

  factory AppSettings.fromMap(Map<String, String> map) {
    final cache = int.tryParse(map[kImageCacheLimitKey] ?? '');
    final pages = int.tryParse(map[kMultiPageLimitKey] ?? '');
    final weight = int.tryParse(map[kQuestionFontWeightKey] ?? '');
    final scale = double.tryParse(map[kUiScaleKey] ?? '');
    final ballSize = double.tryParse(map[kBallSizeKey] ?? '');
    final ballOpacity = double.tryParse(map[kBallOpacityKey] ?? '');
    final strokeWidth = double.tryParse(map[kBallStrokeWidthKey] ?? '');
    final strokeOpacity = double.tryParse(map[kBallStrokeOpacityKey] ?? '');
    String? blank(String? v) => (v == null || v.isEmpty) ? null : v;
    return AppSettings(
      theme: ThemeMode2.values.firstWhere(
        (t) => t.name == map['theme'],
        orElse: () => ThemeMode2.system,
      ),
      fontSize: double.tryParse(map['font_size'] ?? '') ?? 16,
      clipboardWatch: map['clipboard_watch'] != '0',
      saveImageFiles: map['save_image_files'] != '0',
      listenPort: int.tryParse(map['listen_port'] ?? '') ?? 8765,
      hotkeyJson: blank(map['hotkey_json']),
      appendHotkeyJson: blank(map['hotkey_json_append']),
      finishHotkeyJson: blank(map['hotkey_json_finish']),
      accent: int.tryParse(map['accent'] ?? '') ?? 0xFF16A34A,
      imageCacheLimit:
          cache == null || cache < 0 ? kDefaultImageCacheLimit : cache,
      multiPageLimit: (pages ?? kDefaultMultiPageLimit)
          .clamp(1, kHardMaxPagesPerTask),
      androidRecognitionEnabled: map[kAndroidRecognitionEnabledKey] == '1',
      questionFontWeight: (weight ?? kDefaultQuestionFontWeight)
          .clamp(kMinQuestionFontWeight, kMaxQuestionFontWeight),
      uiScale: (scale ?? 1.0).clamp(kMinUiScale, kMaxUiScale),
      // 布尔项用常量默认值：**不能写成 `map[key] == '1'`** —— 键不存在时那是
      // false，会把构造函数的默认值整个绕过去（M14 第 4 条实测：默认打开悬浮球
      // 之后，全新装的机器上悬浮球依然不显示，日志里连一条 `ball` 都没有，
      // 因为读设置时 ballEnabled 恒为 false）。
      ballEnabled: map[kBallEnabledKey] == null
          ? kDefaultBallEnabled
          : map[kBallEnabledKey] == '1',
      ballSize: (ballSize ?? kDefaultBallSize).clamp(kMinBallSize, kMaxBallSize),
      ballOpacity:
          (ballOpacity ?? kDefaultBallOpacity).clamp(kMinBallOpacity, 1.0),
      ballStroke: map[kBallStrokeKey] == null
          ? kDefaultBallStroke
          : map[kBallStrokeKey] == '1',
      ballStrokeWidth: (strokeWidth ?? kDefaultBallStrokeWidth)
          .clamp(kMinBallStrokeWidth, kMaxBallStrokeWidth),
      ballStrokeOpacity:
          (strokeOpacity ?? kDefaultBallStrokeOpacity).clamp(0.0, 1.0),
    );
  }
}

/// 题目正文字重可选档位（用户反馈 1）：MiSans 是可变字体，直接给 wght 轴。
const List<int> kQuestionFontWeights = [300, 400, 500, 600, 700];
const int kMinQuestionFontWeight = 200;
const int kMaxQuestionFontWeight = 800;
const int kDefaultQuestionFontWeight = 500;

/// 界面缩放（用户反馈 9）：50%–300%。
const double kMinUiScale = 0.5;
const double kMaxUiScale = 3.0;
const double kDefaultUiScale = 1.0;

/// 界面上可选的缩放档位（用户反馈 7：只给这些固定选项，25% 一档）。
/// 数值都是 0.5 的整数倍，避免浮点误差导致 `DropdownButton` 匹配不上。
const List<double> kUiScalePresets = [
  0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5, 2.75, 3.0,
];

/// 悬浮球默认打开（用户反馈 M14 第 4 条）。
///
/// 构造函数与 [`AppSettings.fromMap`] **都要用它**：`fromMap` 里曾经写成
/// `map[kBallEnabledKey] == '1'`，键不存在时得到 false，把这里的默认值绕过去 ——
/// 表现就是「默认打开悬浮球」这个要求怎么改都不生效。
const bool kDefaultBallEnabled = true;

/// 数值 → 最接近的档位（老配置里存了 1.3 这种非档位值时用）。
double nearestUiScalePreset(double value) {
  var best = kUiScalePresets.first;
  var bestDelta = (value - best).abs();
  for (final p in kUiScalePresets) {
    final d = (value - p).abs();
    if (d < bestDelta) {
      best = p;
      bestDelta = d;
    }
  }
  return best;
}

/// AI 配置中**不入安全存储**的部分（API Key 单独走 flutter_secure_storage）。
///
/// 用户反馈 8：默认就填好 DeepSeek 的多模态模型与地址，用户只要粘一个 API Key
/// 就能用（`deepseek-flash` 支持图片输入，base_url 走 OpenAI 兼容的
/// `/chat/completions`）。
class AiUiSettings {
  /// DeepSeek 默认模型（支持图片输入的多模态模型）。
  static const defaultModel = 'deepseek-flash';

  /// DeepSeek 默认 base_url（本项目会拼成 `{baseUrl}/chat/completions`）。
  static const defaultBaseUrl = 'https://api.deepseek.com';

  final String providerId;
  final String model;
  final String baseUrl;
  final int timeoutSeconds;
  final int dailyLimit;

  const AiUiSettings({
    this.providerId = 'openai-compatible',
    this.model = defaultModel,
    this.baseUrl = defaultBaseUrl,
    this.timeoutSeconds = 90,
    this.dailyLimit = 200,
  });

  AiUiSettings copyWith({
    String? providerId,
    String? model,
    String? baseUrl,
    int? timeoutSeconds,
    int? dailyLimit,
  }) =>
      AiUiSettings(
        providerId: providerId ?? this.providerId,
        model: model ?? this.model,
        baseUrl: baseUrl ?? this.baseUrl,
        timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
        dailyLimit: dailyLimit ?? this.dailyLimit,
      );

  Map<String, String> toMap() => {
        'ai_provider': providerId,
        'ai_model': model,
        'ai_base_url': baseUrl,
        'ai_timeout': timeoutSeconds.toString(),
        'ai_daily_limit': dailyLimit.toString(),
      };

  factory AiUiSettings.fromMap(Map<String, String> map) => AiUiSettings(
        providerId: map['ai_provider'] ?? 'openai-compatible',
        model: _nonBlank(map['ai_model']) ?? defaultModel,
        baseUrl: _nonBlank(map['ai_base_url']) ?? defaultBaseUrl,
        timeoutSeconds: int.tryParse(map['ai_timeout'] ?? '') ?? 90,
        dailyLimit: int.tryParse(map['ai_daily_limit'] ?? '') ?? 200,
      );
}

/// 空串 = 用户从没设置过（沿用默认值），不是「显式清空」。
String? _nonBlank(String? v) => (v == null || v.trim().isEmpty) ? null : v;

/// 设置控制器：加载 / 持久化 / 变更通知。
class SettingsController extends ChangeNotifier {
  final KeyValueStore store;

  AppSettings app = const AppSettings();
  AiUiSettings ai = const AiUiSettings();

  /// 隐私告知是否已确认（首次启动弹窗的依据）。
  bool privacyAcknowledged = false;

  SettingsController(this.store);

  Future<void> load() async {
    final map = <String, String>{};
    for (final key in [
      ...AppSettings.fromMap(const {}).toMap().keys,
      ...AiUiSettings.fromMap(const {}).toMap().keys,
      'privacy_ack',
    ]) {
      final v = await store.read(key);
      if (v != null) map[key] = v;
    }
    app = AppSettings.fromMap(map);
    ai = AiUiSettings.fromMap(map);
    privacyAcknowledged = (map['privacy_ack'] ?? '0') == '1';
    notifyListeners();
  }

  Future<void> updateApp(AppSettings settings) async {
    app = settings;
    for (final e in settings.toMap().entries) {
      await store.write(e.key, e.value);
    }
    notifyListeners();
  }

  Future<void> updateAi(AiUiSettings settings) async {
    ai = settings;
    for (final e in settings.toMap().entries) {
      await store.write(e.key, e.value);
    }
    notifyListeners();
  }

  Future<void> acknowledgePrivacy() async {
    privacyAcknowledged = true;
    await store.write('privacy_ack', '1');
    notifyListeners();
  }

  /// Ctrl+滚轮 / 双指捏合缩放。
  Future<void> adjustFontSize(double delta) =>
      updateApp(app.copyWith(fontSize: (app.fontSize + delta).clamp(12, 32)));
}
