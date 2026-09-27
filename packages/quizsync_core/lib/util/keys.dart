/// 本地设置键与默认值（`settings` 表，**不参与同步**）。
/// 两端共用，避免同一个键在桌面端与安卓端写成两个字符串。
library;

/// 当前选中的任务合集。空/缺失 = 尚未选择合集。
const String kActiveCollectionKey = 'active_collection_id';

/// 上次用过的合集：每次打开都要重新选择合集，因此启动时会把
/// `kActiveCollectionKey` 清空，只用这个键在选择页里标出「上次使用」并排首位。
const String kLastCollectionKey = 'last_collection_id';

/// 本地图片缓存上限：默认 60 张，0 = 不设限。
const String kImageCacheLimitKey = 'image_cache_limit';
const int kDefaultImageCacheLimit = 60;

/// 多页识别单次最多页数：默认 6 张。
const String kMultiPageLimitKey = 'multipage_max_pages';
const int kDefaultMultiPageLimit = 6;

/// 服务端硬上限：任何客户端一次任务最多这么多页（防滥用，不受本地设置影响）。
/// 硬上限就是 6 张。
const int kHardMaxPagesPerTask = 6;

/// 安卓「识别模块」总开关：默认关闭。
const String kAndroidRecognitionEnabledKey = 'android_recognition_enabled';

/// 题目正文字重：MiSans 可变字体的 wght 轴，默认 400。
const String kQuestionFontWeightKey = 'question_font_weight';

/// 界面整体缩放：0.5–3.0，默认 1.0。
const String kUiScaleKey = 'ui_scale';

// ---------------------------------------------------------------------------
// Windows 悬浮球
// ---------------------------------------------------------------------------

/// 是否显示悬浮球：**默认打开**。
/// 悬浮球开关。
///
/// **：默认改成关闭** —— 和悬浮窗一样，装完不主动占屏幕。
/// 老库里存着 `ball_enabled=1`（那时的出厂值就是开），由 `SettingsController.load()`
/// 做一次性迁移（见 [kBallEnabledMigratedKey]）。
const String kBallEnabledKey = 'ball_enabled';
const bool kDefaultBallEnabled = false;

/// 一次性迁移标记：悬浮球默认从「开」改成「关」。
const String kBallEnabledMigratedKey = 'ball_enabled_migrated';

/// 悬浮球边长（逻辑像素）：**默认 40**，范围 [kMinBallSize]–[kMaxBallSize]。
const String kBallSizeKey = 'ball_size';
const double kMinBallSize = 32;
const double kMaxBallSize = 96;
const double kDefaultBallSize = 40;

/// 悬浮球整体不透明度：**默认 0.70**，范围 [kMinBallOpacity]–1.0。
const String kBallOpacityKey = 'ball_opacity';
const double kMinBallOpacity = 0.2;
const double kDefaultBallOpacity = 0.7;

/// 描边开关（颜色取悬浮球当前状态的主色并**加深**）。
///
/// **默认打开**（默认值必须走常量，不能写成 `map[key] == '1'` ——
/// 键不存在时那是 false，会把默认值绕过去已经踩过一次）。
const String kBallStrokeKey = 'ball_stroke';
const bool kDefaultBallStroke = true;

/// 描边宽度（逻辑像素）与描边不透明度：默认 4 / 25%。
const String kBallStrokeWidthKey = 'ball_stroke_width';
const double kMinBallStrokeWidth = 0;
const double kMaxBallStrokeWidth = 10;
const double kDefaultBallStrokeWidth = 4;

const String kBallStrokeOpacityKey = 'ball_stroke_opacity';
const double kDefaultBallStrokeOpacity = 0.25;

/// 描边向**球内**多画出来的宽度（逻辑像素）。
///
/// 球素材不是标准圆形（球的外缘与「半径 = 球边/2」的环带内缘之间会露出空隙），
/// 所以环带要从球半径处**再往内重叠**这么多，把缝糊上。描边画在球的**下面**，
/// 球体本身不会被染色；只有球边缘真正透明的地方才看得见这层内重叠。
const double kBallStrokeInset = 2;

// ---------------------------------------------------------------------------
// Windows 悬浮窗
// ---------------------------------------------------------------------------

/// 悬浮窗总开关：**默认关闭**。
///
/// 与悬浮球一样，布尔项在 `AppSettings.fromMap` 里必须用**常量默认值**兜底 ——
/// 写成 `map[key] == '1'` 时键不存在会得到 false，把这里的默认值整个绕过去
/// （悬浮球开关就在这里踩过坑）。
const String kFloatWindowEnabledKey = 'float_window_enabled';
const bool kDefaultFloatWindowEnabled = false;

/// 是否置顶显示：默认置顶。
const String kFloatWindowTopmostKey = 'float_window_topmost';
const bool kDefaultFloatWindowTopmost = true;

/// 整体透明度：默认 90%，
/// 范围 [kMinFloatWindowOpacity]–1.0。
const String kFloatWindowOpacityKey = 'float_window_opacity';
const double kMinFloatWindowOpacity = 0.2;
const double kDefaultFloatWindowOpacity = 0.9;

/// 显示比例：**窗口宽度的倍率**，
/// 基准宽由外观（[FloatWindowAspect]）决定，因此高度 = 宽度 / 宽高比。默认 1.0。
const String kFloatWindowScaleKey = 'float_window_scale';
const double kMinFloatWindowScale = 0.5;
const double kMaxFloatWindowScale = 3.0;
const double kDefaultFloatWindowScale = 1.0;

/// 窗内字符大小倍率：默认 1.0，0.6–2.0。
const String kFloatWindowFontScaleKey = 'float_window_font_scale';
const double kMinFloatWindowFontScale = 0.6;
const double kMaxFloatWindowFontScale = 2.0;
const double kDefaultFloatWindowFontScale = 1.0;

/// 外观：**三选一的宽高比**，不再允许自由拉伸。
///
/// 不支持边界拉伸：仅可在（标准外观）9:20、（加长外观）9:30、
/// （横向外观）20:9 之间选择，默认比例 9:20（竖屏）。
///
/// 每种外观自带**基准宽度**（100% 比例时的逻辑宽度）—— 竖屏外观如果沿用横向的
/// 560，9:20 会得到 1244 逻辑像素高，连 1000 高的桌面都放不下。
const String kFloatWindowAspectKey = 'float_window_aspect';

class FloatWindowAspect {
  const FloatWindowAspect(this.id, this.label, this.hint, this.ratio,
      this.baseWidth);

  /// 落库用的稳定 id。
  final String id;

  /// 设置页显示名。
  final String label;

  /// 一句话说明（宽度 → 高度）。
  final String hint;

  /// 宽高比 `宽 / 高`。
  final double ratio;

  /// 100% 比例时的基准宽度（逻辑像素）。
  final double baseWidth;

  double widthAt(double scale) => baseWidth * scale;
  double heightAt(double scale) => widthAt(scale) / ratio;

  /// 「9:20」这样的比例文案。
  String get ratioLabel => _ratioLabelOf(ratio);
}

String _ratioLabelOf(double ratio) {
  if ((ratio - 9 / 20).abs() < 1e-6) return '9:20';
  if ((ratio - 9 / 30).abs() < 1e-6) return '9:30';
  if ((ratio - 20 / 9).abs() < 1e-6) return '20:9';
  return ratio.toStringAsFixed(2);
}

const List<FloatWindowAspect> kFloatWindowAspects = [
  FloatWindowAspect('portrait', '标准外观（竖屏 9:20）', '342 × 760', 9 / 20, 342),
  FloatWindowAspect('tall', '加长外观（竖屏 9:30）', '270 × 900', 9 / 30, 270),
  FloatWindowAspect('landscape', '横向外观（20:9）', '560 × 252', 20 / 9, 560),
];

/// 默认外观：**竖屏 9:20**。
const String kDefaultFloatWindowAspect = 'portrait';

FloatWindowAspect floatWindowAspectOf(String? id) => kFloatWindowAspects
    .firstWhere((a) => a.id == id, orElse: () => kFloatWindowAspects.first);

/// 配色主题：悬浮窗的底色/卡片/主色预设，**默认是浅色系**。
const String kFloatWindowPaletteKey = 'float_window_palette';

class FloatWindowPaletteSpec {
  const FloatWindowPaletteSpec(this.id, this.label, this.seed);

  final String id;
  final String label;

  /// 主色种子（ARGB）：卡片里的标绿/徽标仍按契约走，这一项决定窗口底色与按钮主色。
  final int seed;
}

const List<FloatWindowPaletteSpec> kFloatWindowPalettes = [
  // 「纯净白」必须是**中性**的：这里若错填绿色（如 0xFF16A34A，和「薄荷绿」
  // 0xFF0F9D58 几乎同色），选了纯净白也会满窗发绿。
  // 中性灰蓝做种子 → 底色是干净的白，主色按钮是中性深灰。
  FloatWindowPaletteSpec('white', '纯净白（默认）', 0xFF64748B),
  FloatWindowPaletteSpec('mint', '薄荷绿', 0xFF0F9D58),
  FloatWindowPaletteSpec('sky', '天空蓝', 0xFF2563EB),
  FloatWindowPaletteSpec('lilac', '丁香紫', 0xFF7C3AED),
  FloatWindowPaletteSpec('sand', '暖沙', 0xFFD97706),
  FloatWindowPaletteSpec('rose', '樱粉', 0xFFDB2777),
];

const String kDefaultFloatWindowPalette = 'white';

/// 选到这几套配色时**同时切到深色模式**。
///
/// 原因：`white`（纯净白）与 `lilac`（紫罗兰）在浅色下，正文/答案与窗口底色的
/// 对比度太低；深色下这两套反而
/// 最耐看，所以直接替用户把明暗模式摆到深色。
const Set<String> kFloatWindowDarkPalettes = {'white', 'lilac'};

FloatWindowPaletteSpec floatWindowPaletteOf(String? id) =>
    kFloatWindowPalettes.firstWhere((p) => p.id == id,
        orElse: () => kFloatWindowPalettes.first);

/// 位置是否锁定：默认解锁（可以拖动）。
const String kFloatWindowLockedKey = 'float_window_locked';
const bool kDefaultFloatWindowLocked = false;

/// 明暗模式：默认 `followApp`（跟随软件设置）。
const String kFloatWindowThemeKey = 'float_window_theme';

/// 极简模式（只看题目答案）。
///
/// **默认开 = 「默认模式」**（用户口径：极简模式就是悬浮窗默认显示的模式）；
/// 关掉它才是「详细解析模式」（选项全列 + 解析 + 阅读材料，与主界面一致）。
const String kFloatWindowMinimalKey = 'float_window_minimal';
const bool kDefaultFloatWindowMinimal = true;

/// 一次性迁移标记：默认显示模式从「详细解析」改成「默认模式（极简）」。
///
/// 老库里存着 `float_window_minimal=0`（那时出厂值就是 0，绝大多数人从没手动选过），
/// 光改常量默认值救不了他们 ——「把极简模式改成默认显示的模式」这个要求会落空。
/// 所以 `SettingsController.load()` 只要没见到这个标记，就把显示模式摆一次新默认值；
/// 之后用户自己切过的模式一律以库里的值为准（标记已存在，不再迁移）。
const String kFloatWindowModeMigratedKey = 'float_window_mode_migrated';

/// 窗口左上角坐标（**逻辑像素**）；`< 0` 表示「还没摆过」→ 走默认位置
/// （屏幕右侧、不贴边）。
const String kFloatWindowXKey = 'float_window_x';
const String kFloatWindowYKey = 'float_window_y';
const double kFloatWindowNoPosition = -1;

/// 默认位置距屏幕右边 / 顶部的留白。
const double kFloatWindowDefaultMarginX = 24;
const double kFloatWindowDefaultMarginY = 120;

// ---------------------------------------------------------------------------
// Windows「连接设备」
// ---------------------------------------------------------------------------

/// 局域网连接总开关：**默认关闭**。
///
/// 关着的时候**不启动内置服务端**，因此这台电脑不监听任何端口、也不碰网络；
/// 用户打开开关时才启动服务（Windows 会弹防火墙授权窗口，这就是「获取网络权限」），
/// 关闭时把它停掉。设置页「连接设备」下方的配对、二维码、设备列表都跟着它一起
/// 变成不可用。
const String kConnectEnabledKey = 'connect_enabled';
const bool kDefaultConnectEnabled = false;
