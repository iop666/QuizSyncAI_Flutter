/// 本地设置键与默认值（`settings` 表，**不参与同步**）。
/// 两端共用，避免同一个键在桌面端与安卓端写成两个字符串。
library;

/// 当前选中的任务合集（用户需求 8/12）。空/缺失 = 尚未选择合集。
const String kActiveCollectionKey = 'active_collection_id';

/// 上次用过的合集：用户需求 8 要求「每次打开都要选择合集」，因此启动时会把
/// `kActiveCollectionKey` 清空，只用这个键在选择页里标出「上次使用」并排首位。
const String kLastCollectionKey = 'last_collection_id';

/// 本地图片缓存上限（用户需求 5）：默认 60 张，0 = 不设限。
const String kImageCacheLimitKey = 'image_cache_limit';
const int kDefaultImageCacheLimit = 60;

/// 多页识别单次最多页数（用户需求 4）：默认 6 张。
const String kMultiPageLimitKey = 'multipage_max_pages';
const int kDefaultMultiPageLimit = 6;

/// 服务端硬上限：任何客户端一次任务最多这么多页（防滥用，不受本地设置影响）。
/// 用户反馈 9：硬上限就是 6 张（原来写 12，与用户要求不符）。
const int kHardMaxPagesPerTask = 6;

/// 安卓「识别模块」总开关（用户需求 11）：默认关闭。
const String kAndroidRecognitionEnabledKey = 'android_recognition_enabled';

/// 题目正文字重（用户反馈 1）：MiSans 可变字体的 wght 轴，默认 400。
const String kQuestionFontWeightKey = 'question_font_weight';

/// 界面整体缩放（用户反馈 9）：0.5–3.0，默认 1.0。
const String kUiScaleKey = 'ui_scale';

// ---------------------------------------------------------------------------
// Windows 悬浮球（用户反馈 11）
// ---------------------------------------------------------------------------

/// 是否显示悬浮球：**默认打开**（M14 第 4 条：用户明确要求默认开）。
const String kBallEnabledKey = 'ball_enabled';

/// 悬浮球边长（逻辑像素）：**默认 40**（M17 第 1 条），范围 [kMinBallSize]–[kMaxBallSize]。
const String kBallSizeKey = 'ball_size';
const double kMinBallSize = 32;
const double kMaxBallSize = 96;
const double kDefaultBallSize = 40;

/// 悬浮球整体不透明度：**默认 0.70**（M17 第 1 条），范围 [kMinBallOpacity]–1.0。
const String kBallOpacityKey = 'ball_opacity';
const double kMinBallOpacity = 0.2;
const double kDefaultBallOpacity = 0.7;

/// 描边开关（颜色取悬浮球当前状态的主色并**加深**）。
///
/// M17 第 1 条：**默认打开**（默认值必须走常量，不能写成 `map[key] == '1'` ——
/// 键不存在时那是 false，会把默认值绕过去，M14 第 4 条已经踩过一次）。
const String kBallStrokeKey = 'ball_stroke';
const bool kDefaultBallStroke = true;

/// 描边宽度（逻辑像素）与描边不透明度：默认 4 / 25%（M17 第 1 条）。
const String kBallStrokeWidthKey = 'ball_stroke_width';
const double kMinBallStrokeWidth = 0;
const double kMaxBallStrokeWidth = 10;
const double kDefaultBallStrokeWidth = 4;

const String kBallStrokeOpacityKey = 'ball_stroke_opacity';
const double kDefaultBallStrokeOpacity = 0.25;

/// 描边向**球内**多画出来的宽度（逻辑像素，M17 第 1 条）。
///
/// 球素材不是标准圆形（球的外缘与「半径 = 球边/2」的环带内缘之间会露出空隙），
/// 所以环带要从球半径处**再往内重叠**这么多，把缝糊上。描边画在球的**下面**，
/// 球体本身不会被染色；只有球边缘真正透明的地方才看得见这层内重叠。
const double kBallStrokeInset = 2;
