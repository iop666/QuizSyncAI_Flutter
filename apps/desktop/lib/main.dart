import 'dart:async';
import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:quizsync_core/quizsync_core.dart';
import 'package:quizsync_ui/quizsync_ui.dart' show QuizSyncTheme;
import 'package:tray_manager/tray_manager.dart';
import 'package:win32/win32.dart' show
    FindWindow, MessageBox, SetForegroundWindow, ShowWindow,
    MB_ICONINFORMATION, MB_OK, SW_RESTORE;
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'services/desktop_server.dart';
import 'services/floating_ball.dart';
import 'services/hotkey_service.dart';
import 'services/hotkeys.dart';
import 'services/window_theme.dart';
import 'state/app_info.dart';
import 'state/app_scope.dart';
import 'state/capture_coordinator.dart';
import 'state/collections.dart';
import 'services/secure_store.dart';
import 'state/settings.dart';
import 'ui/collection_picker_page.dart';
import 'ui/home_page.dart' show dataRootProvider;
import 'ui/settings_page.dart';

final _navigatorKey = GlobalKey<NavigatorState>();

/// 单实例信号量名（拿到计数 0→1 的实例常驻运行；进程退出由系统回收）。
const _kMutexName = 'QuizSyncAI_SingleInstance_7C6E1F42';

final _kernel32 = DynamicLibrary.open('kernel32.dll');
final _createSemaphoreW = _kernel32.lookupFunction<
    IntPtr Function(Pointer<Void>, Int32, Int32, Pointer<Utf16>),
    int Function(Pointer<Void>, int, int, Pointer<Utf16>)>('CreateSemaphoreW');
final _waitForSingleObject = _kernel32
    .lookupFunction<Uint32 Function(IntPtr, Uint32), int Function(int, int)>(
        'WaitForSingleObject');
final _closeHandle =
    _kernel32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'CloseHandle');

Pointer<Utf16> _winStr(String s) => s.toNativeUtf16();
final Pointer<Utf16> _nullWideStr = Pointer<Utf16>.fromAddress(0);

/// 二次启动：唤出已运行实例的主窗口并提示，然后退出当前进程。
/// 注意不能用 CreateMutexW+GetLastError：Dart FFI 不保证 last-error 跨调用
/// 保持（实测第二实例读到 0 而绕过检查）；信号量方案只看返回值。
void _enforceSingleInstance() {
  // initial=1：第一个实例拿到唯一计数（1→0），后来者 WaitForSingleObject 超时。
  final semName = _winStr(_kMutexName);
  final sem = _createSemaphoreW(Pointer<Void>.fromAddress(0), 1, 1, semName);
  calloc.free(semName);
  if (sem == 0) return; // 创建失败：宁可放行也不锁死应用
  // WAIT_OBJECT_0(0)=抢到唯一计数；WAIT_TIMEOUT(0x102)=已有实例持有。
  if (_waitForSingleObject(sem, 0) == 0) return; // 我们是第一个实例，持有不放
  _closeHandle(sem);
  final title = _winStr(kAppName);
  final hwnd = FindWindow(_nullWideStr, title);
  if (hwnd != 0) {
    ShowWindow(hwnd, SW_RESTORE);
    SetForegroundWindow(hwnd);
  }
  final body = _winStr('$kAppName 正在运行，已为你唤出主窗口。\n（可从托盘图标使用截屏热键）');
  MessageBox(
      _nullWideStr.address, body, title, MB_ICONINFORMATION | MB_OK);
  // 分配的原生字符串要释放（进程马上退出，但别留下 FFI 泄漏的坏习惯）。
  calloc.free(title);
  calloc.free(body);
  exit(0);
}

// 热键的候选键、键位映射与标签逻辑都在 services/hotkeys.dart（可单测）。

/// 应用数据目录解析（用户反馈 10）：**默认放在应用所在目录下**。
///
/// 便携版最直观的语义是「整个文件夹拷走 = 数据一起走」，所以优先用
/// `<exe 所在目录>\userdata`；但如果安装到 `Program Files` 这类只读位置
/// （选择以管理员身份安装时），创建/写入会失败，这时退回系统给的应用数据
/// 目录，保证功能不受影响（数据位置在「设置 → 数据管理」里如实显示）。
///
/// **为什么叫 `userdata` 而不是 `data`**：Flutter 的 Windows release 产物本身
/// 就有一个 `<exe>\data\` 目录（里面是 `app.so` / `flutter_assets` / `icudtl.dat`），
/// 用它装用户数据会和引擎载荷混在一起 —— 实测「清理 app 数据」会把引擎删掉，
/// 程序再也起不来。所以固定用一个独立子目录。
///
/// 还会兼容**旧版本**已经写在 `%LOCALAPPDATA%` 下的数据：旧目录里有
/// `quizsync.db` 而新目录里还没有时，**一次性把旧数据复制过来**（见
/// [migrateLegacyData]），然后照常用新目录 —— 既满足「数据放在应用目录下」，
/// 又不会让老用户「升级后历史记录全没了」。复制失败（磁盘满 / 只读）时
/// 继续用旧目录，绝不丢数据。
///
/// [exeDir] / [legacyDir] 只为单测注入（生产走真实路径）。
Future<String> resolveDataDir({String? exeDir, String? legacyDir}) async {
  final exe = exeDir ?? File(Platform.resolvedExecutable).parent.path;
  final sep = Platform.pathSeparator;
  final portable = Directory('$exe$sep$kPortableDataDirName');
  final legacy = legacyDir ?? await _supportDataDir();
  final fallback = legacy ?? '${Directory.systemTemp.path}${sep}quizsync';

  final portableDb = File('${portable.path}${sep}quizsync.db');
  final legacyDb = legacy == null ? null : File('$legacy${sep}quizsync.db');

  // 只有「旧库存在 + 新库不存在」才需要搬家。
  if (legacy != null &&
      legacyDb!.existsSync() &&
      !portableDb.existsSync()) {
    if (await migrateLegacyData(legacy, portable)) {
      AppLogger.instance
          .info('data', '已把旧数据搬到应用目录：$legacy → ${portable.path}');
      return portable.path;
    }
    AppLogger.instance.warn('data', '旧数据搬家失败，继续使用旧目录：$legacy');
    return legacy;
  }

  try {
    await portable.create(recursive: true);
    // 注意 `$portable.path` 会把整个 Directory 插进字符串（要写成 `${portable.path}`）。
    final probe = File('${portable.path}$sep.writable');
    await probe.writeAsString('ok', flush: true);
    await probe.delete();
    return portable.path;
  } catch (e) {
    AppLogger.instance.warn('data', '应用目录不可写（$e），改用系统数据目录：$fallback');
    return fallback;
  }
}

/// 便携版数据目录名（放在 exe 旁边；不能叫 `data`，那是 Flutter 引擎载荷目录）。
const String kPortableDataDirName = 'userdata';

/// 把旧数据目录整体**复制**到新目录（不删旧目录，留个后路）。
/// 返回 true 表示新目录里已经有了可用的 `quizsync.db`。
Future<bool> migrateLegacyData(String legacyPath, Directory target) async {
  final sep = Platform.pathSeparator;
  try {
    final src = Directory(legacyPath);
    if (!src.existsSync()) return false;
    await target.create(recursive: true);
    // 顶层文件：库、secure.bin、其他零散文件（跳过临时标记）。
    for (final entity in src.listSync()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (name.isEmpty || name == '.writable') continue;
      final dest = File('${target.path}$sep$name');
      if (dest.existsSync()) continue;
      await entity.copy(dest.path);
    }
    // 子目录：图片 / 备份 / 导出一起搬（日志不搬，重新生成即可）。
    for (final sub in const ['images', 'backups', 'exports']) {
      final from = Directory('$legacyPath$sep$sub');
      if (!from.existsSync()) continue;
      final to = Directory('${target.path}$sep$sub');
      await to.create(recursive: true);
      for (final entity in from.listSync()) {
        if (entity is! File) continue;
        final dest =
            File('${to.path}$sep${entity.uri.pathSegments.last}');
        if (dest.existsSync()) continue;
        await entity.copy(dest.path);
      }
    }
    return File('${target.path}${sep}quizsync.db').existsSync();
  } catch (e) {
    AppLogger.instance.warn('data', '拆迁旧数据失败：$e');
    return false;
  }
}

/// 旧版本的数据目录；平台通道不可用时返回 null（只可能出现在单测里）。
Future<String?> _supportDataDir() async {
  try {
    final support = await getApplicationSupportDirectory();
    return '${support.path}${Platform.pathSeparator}quizsync';
  } catch (_) {
    return null;
  }
}

/// 100% 缩放时的基准窗口尺寸（与启动时的 `WindowOptions` 一致）。
///
/// 用户反馈 8：缩放后窗口边界要能真的"跟住内容"。启动时如果存的是非 100%
/// 的缩放，就把窗口按这个基准 × 缩放比摆好，避免"界面小了、边框还是原来那么大"
/// 留出一大片画布（深色主题下就是一片黑）。
const Size kBaseWindowSize = Size(1180, 760);

/// 100% 缩放时的窗口最小尺寸（与启动时的 `WindowOptions.minimumSize` 一致）。
///
/// 用户反馈 8：最小尺寸也要跟着缩放走。否则缩到 50% 时窗口被卡在 860×520，
/// 界面只剩一半大小、剩下全是画布色（深色下就是一片黑）——看起来就是
/// 「边框没有跟着内容缩放」。
const Size kBaseMinimumWindowSize = Size(860, 520);

/// 按缩放比放开窗口最小尺寸（否则缩小会被旧的最小尺寸卡住）。
Future<void> _applyScaledMinimumSize(
    double scale, double maxW, double maxH) async {
  final minW = math.min(kBaseMinimumWindowSize.width * scale, maxW);
  final minH = math.min(kBaseMinimumWindowSize.height * scale, maxH);
  await windowManager.setMinimumSize(Size(minW, minH));
}

/// 界面缩放变化后按同比例调整**窗口边界**（用户反馈 7/8）。
///
/// 缩放是「虚拟画布 + 整体放大」实现的：100% 时的窗口装 1180×760 逻辑像素，
/// 200% 时同样一块窗口只剩 590×380 逻辑像素，界面会显得挤。所以这里在缩放
/// 比例变化时把窗口物理尺寸乘以同一个比例，再夹到当前显示器工作区内。
///
/// 用户反馈 8 的三处修正：
///  1. **窗口最大化时 `setBounds` 会被系统忽略**（用户看到"边框完全没动"），
///     所以先 `unmaximize`；
///  2. **最小尺寸也要按比例缩放** —— 原来缩到 50% 时窗口被 860×520 的最小
///     尺寸卡住，界面只剩一半，其余全是画布色（深色下就是一片黑）；
///  3. 设完之后回读一次真实尺寸写进日志 —— 界面是不是真的跟住了，看日志就知道，
///     不再靠肉眼判断。
Future<void> applyUiScaleToWindow(
  double newScale, {
  required double previousScale,
}) async {
  if (previousScale <= 0 || !newScale.isFinite || newScale <= 0) return;
  final factor = newScale / previousScale;
  if ((factor - 1).abs() < 0.001) return;
  try {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    }
    final size = await windowManager.getSize();
    final position = await windowManager.getPosition();
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final display = view.display;
    final maxW = display.size.width / view.devicePixelRatio;
    final maxH = display.size.height / view.devicePixelRatio;
    await _applyScaledMinimumSize(newScale, maxW, maxH);

    final w = (size.width * factor).clamp(1.0, maxW).toDouble();
    final h = (size.height * factor).clamp(1.0, maxH).toDouble();
    // 缩放后不要跑到屏幕外面：左上角最多放到「屏幕 - 窗口」的位置。
    final x = position.dx.clamp(0.0, math.max(0.0, maxW - w)).toDouble();
    final y = position.dy.clamp(0.0, math.max(0.0, maxH - h)).toDouble();
    await windowManager.setBounds(Rect.fromLTWH(x, y, w, h));
    final actual = await windowManager.getSize();
    AppLogger.instance.info(
        'window',
        '界面缩放后窗口：请求 ${w.round()}×${h.round()}（$previousScale→$newScale）'
            '→ 实际 ${actual.width.round()}×${actual.height.round()}');
  } catch (e) {
    AppLogger.instance.warn('window', '按缩放调整窗口大小失败：$e');
  }
}

/// 启动时按已保存的缩放比把窗口摆成「基准尺寸 × 缩放比」。
///
/// 只在启动时做一次：之后用户手动拖出来的窗口大小会被尊重（改缩放时按比例走）。
Future<void> applyStoredUiScaleToWindow(double scale) async {
  if ((scale - 1.0).abs() < 0.001) return;
  try {
    if (await windowManager.isMaximized()) return; // 最大化是用户的明确选择
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final display = view.display;
    final maxW = display.size.width / view.devicePixelRatio;
    final maxH = display.size.height / view.devicePixelRatio;
    await _applyScaledMinimumSize(scale, maxW, maxH);
    final w = (kBaseWindowSize.width * scale).clamp(1.0, maxW).toDouble();
    final h = (kBaseWindowSize.height * scale).clamp(1.0, maxH).toDouble();
    await windowManager.setSize(Size(w, h));
    final actual = await windowManager.getSize();
    AppLogger.instance.info('window',
        '启动按已保存缩放（$scale）设定窗口 ${w.round()}×${h.round()}'
        '→ 实际 ${actual.width.round()}×${actual.height.round()}');
  } catch (e) {
    AppLogger.instance.warn('window', '启动应用缩放失败：$e');
  }
}

/// 手机（安卓）发起识别时的窗口动作（用户反馈 12）：
/// 把主窗口带到前台、回到主界面，并让主界面跳到这次识别的会话。
Future<void> _onRemoteTaskStarted(String sessionId) async {
  remoteTaskSession.value = sessionId;
  try {
    if (!await windowManager.isVisible()) {
      await windowManager.show();
    }
    await windowManager.focus();
  } catch (e) {
    AppLogger.instance.warn('window', '手机任务唤起窗口失败：$e');
  }
  // 用户可能正停在设置页：先回到首层，识别界面才看得见。
  final nav = _navigatorKey.currentState;
  if (nav != null && nav.canPop()) {
    nav.popUntil((r) => r.isFirst);
  }
}

Future<void> main() async {
  _enforceSingleInstance();
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  final dataDir = await resolveDataDir();
  final imageDir = '$dataDir/images';

  // M12：日志落盘（`<数据目录>/logs/app.log`）。用户报障时「导出日志」一旦
  // 本身失败就什么都拿不到，所以启动即挂文件 sink，写失败静默退回内存日志。
  AppLogger.instance.attachFile('$dataDir/logs/app.log');
  AppLogger.instance.info('app', '启动：数据目录 $dataDir');

  // 上次运行期点过「恢复备份」但当时库文件被占用 → 在这里（打开数据库之前）
  // 换入暂存的库。
  BackupManager.applyPendingRestore('$dataDir/quizsync.db');

  final db = openQuizSyncDb('$dataDir/quizsync.db');
  final repo = CoreRepository(db: db, deviceId: 'windows-local');
  await repo.init();

  final settings = SettingsController(DriftKeyValueStore(repo));
  await settings.load();
  // 用户需求 8：「每次打开都要选择合集」。启动时清空「当前选中」，只把上次用
  // 的合集记下来给选择页标「上次使用」——否则热键/剪贴板会在用户还没选之前
  // 就把新记录写进上次的合集，手机端也会看到一个陈旧的选中项（用户需求 12）。
  final lastCollectionId = await repo.getSetting(kActiveCollectionKey);
  if (lastCollectionId != null && lastCollectionId.isNotEmpty) {
    await repo.setSetting(kLastCollectionKey, lastCollectionId);
    await repo.setSetting(kActiveCollectionKey, '');
  }
  final secureStore = WindowsSecureStore('$dataDir/secure.bin');

  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(1180, 760),
      minimumSize: Size(860, 520),
      title: kAppName,
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
      // 用户反馈 8：上次用的是非 100% 缩放时，窗口要按同样比例摆好，
      // 否则界面范围与窗口边界对不上（深色主题下右边/下面就是一片黑）。
      await applyStoredUiScaleToWindow(settings.app.uiScale);
    },
  );

  // M4：内置服务端随应用启动（端口来自设置；占用自动探测 +1）。
  final serverController = DesktopServerController();
  Future<String?> keyReader() => secureStore.read('ai_api_key');
  await serverController.start(
    repo: repo,
    registry: {
      'openai-compatible': OpenAiCompatibleProvider(),
      'anthropic': AnthropicProvider(),
      'gemini': GeminiProvider(),
    },
    aiSettingsReader: () => settings.ai,
    keyReader: keyReader,
    imageDir: imageDir,
    preferredPort: settings.app.listenPort,
    // 用户反馈 12：手机发起的识别 → Windows 端要「显示识别界面」；
    // 本机截屏不在这里（走 AnalysisWorkflow），保持后台静默。
    onTaskUpdate: (status, sessionId) {
      if (status != 'analyzing' || sessionId == null) return;
      unawaited(_onRemoteTaskStarted(sessionId));
    },
  );
  runApp(ProviderScope(
    overrides: [
      dbProvider.overrideWithValue(db),
      repoProvider.overrideWithValue(repo),
      settingsProvider.overrideWith((ref) => settings),
      serverControllerProvider.overrideWithValue(serverController),
      // 不恢复上次的选中项：用户需求 8 要求每次打开都重新选一次合集。
      activeCollectionIdProvider.overrideWith((ref) => null),
      apiKeyReaderProvider.overrideWithValue(keyReader),
      dataRootProvider.overrideWithValue(dataDir),
      apiKeyWriterProvider.overrideWithValue((key) async {
        if (key.isEmpty) {
          await secureStore.delete('ai_api_key');
        } else {
          await secureStore.write('ai_api_key', key);
        }
      }),
    ],
    child: _DesktopShell(imageDir: imageDir),
  ));
}

/// 桌面外壳：托盘 + 全局热键 + 窗口生命周期（SPEC 2.4）。
class _DesktopShell extends ConsumerStatefulWidget {
  final String imageDir;
  const _DesktopShell({required this.imageDir});

  @override
  ConsumerState<_DesktopShell> createState() => _DesktopShellState();
}
class _DesktopShellState extends ConsumerState<_DesktopShell>
    with WindowListener, TrayListener, WidgetsBindingObserver {
  late final CaptureCoordinator coordinator;
  final HotkeyService _hotkey = HotkeyService();
  Timer? _hotkeyReloadTimer;

  /// Windows 悬浮球（用户反馈 11）。
  late final FloatingBall _ball;
  bool _ballStarted = false;

  @override
  void initState() {
    super.initState();
    trayManager.addListener(this);
    windowManager.addListener(this);
    windowManager.setPreventClose(true);
    WidgetsBinding.instance.addObserver(this);
    coordinator = CaptureCoordinator(
      refOf: () => ref,
      contextOf: () => _navigatorKey.currentContext ?? context,
      imageDir: widget.imageDir,
    );
    final app0 = ref.read(settingsProvider).app;
    _ball = FloatingBall(
      onTap: _onBallTap,
      onLongPress: _onBallLongPress,
      sizePx: app0.ballSize,
      opacity: app0.ballOpacity,
      strokeEnabled: app0.ballStroke,
      strokeWidth: app0.ballStrokeWidth,
      strokeOpacity: app0.ballStrokeOpacity,
    );
    // 截屏时球必须一起藏起来（否则会被拍进发给 AI 的图里）。
    coordinator.capture.overlayHiders.add(_ball.setVisibleForCapture);
    _setupHotkey().then((_) => _setupTray());
    _syncClipboard();
    _applyWindowTheme();
    // 暂存页数变化时刷新托盘提示（用户反馈 5/12：后台静默攒页，托盘是唯一提示）。
    coordinator.stagingListeners.add(_setupTray);
    // 悬浮球跟着「攒了几页 / 是否正在识别」换状态图（用户反馈 11）。
    coordinator.stagingListeners.add(_syncBallState);
    coordinator.busyListeners.add(_syncBallState);
    ref.listenManual(settingsProvider.select((s) => s.app.clipboardWatch),
        (prev, next) => _syncClipboard());
    // 悬浮球设置变化 → 立刻作用到窗口上（开关 / 大小 / 透明度 / 描边）。
    //
    // 用户反馈 M15 第 1 条（大小 / 透明度 / 描边 / 开关「全都调不动」）：
    // 这里原来是 `ref.listenManual(settingsProvider, (prev, next) { ... })`，
    // 而 `settingsProvider` 是 `ChangeNotifierProvider`，它的**值就是那个 controller
    // 实例本身** —— 通知到达时 `prev` 与 `next` 是同一个对象，两边读到的都是
    // **已经更新过**的 `app`，于是 `before == after` 永远成立、直接 return，
    // `_applyBallSettings()` 从来没被调用过（球一直停在启动时的默认外观）。
    // 用 `select` 把「签名」抽出来，`prev/next` 才是真正的旧值/新值。
    ref.listenManual(
      settingsProvider.select((s) => _ballSignature(s.app)),
      (prev, next) {
        if (prev == next) return;
        unawaited(_applyBallSettings());
      },
    );
    // 主题三态变化 → Windows 标题栏深浅跟着变（用户反馈 7）。
    ref.listenManual(settingsProvider.select((s) => s.app.theme),
        (prev, next) => _applyWindowTheme());
    // 界面缩放变化 → 窗口边界按同比例调整（用户反馈 7/8）。
    ref.listenManual(settingsProvider.select((s) => s.app.uiScale),
        (prev, next) {
      if (prev == null || prev == next) return;
      if (prev <= 0) return;
      unawaited(applyUiScaleToWindow(next, previousScale: prev));
    });
    // 设置页改任意一个热键 → 防抖后重新注册（录制时按键会连发多次回调）。
    //
    // 修（用户反馈 14）：原来只监听「截图识别」那一个 `hotkeyJson`，
    // 改「添加页面 / 结束多页识别」两个热键时**根本不会重新注册** ——
    // 表现就是「多页热键设置了不生效」，用户以为没保存成功。
    //
    // 修（M15）：这里原来也是直接 listen 整个 provider，`prev/next` 是同一个
    // controller 实例，签名比较永远相等 → 改热键同样不会重新注册。改走 `select`。
    ref.listenManual(
      settingsProvider.select((s) => hotkeySettingsSignature(s.app)),
      (prev, next) {
        if (prev == next) return;
        _hotkeyReloadTimer?.cancel();
        _hotkeyReloadTimer = Timer(const Duration(milliseconds: 500), () {
          _setupHotkey().then((_) => _setupTray());
        });
      },
    );
    // 设置页点「重新注册全部热键」→ 立刻重来一遍。
    ref.listenManual(hotkeyReloadProvider, (prev, next) {
      _setupHotkey().then((_) => _setupTray());
    });
    // 用户反馈 5 + M31：进热键设置页时**不再注销**全局热键，改成「触发时丢弃」。
    //
    // M30 的做法（进页 `unregister()`、离页重注册）在「页面没被卸载」时会把热键
    // **永久**锁死 —— 窗口收进托盘 / 最小化时页面不会 dispose，标志一直是 true，
    // 而 M30 又让暂停期间跳过重新注册，于是用户在**任何地方**按都没反应（实测）。
    // 现在注册始终有效，只在触发那一刻看「本页是不是正在前台」；这里只留一条日志，
    // 让「为什么按了没反应」在日志里看得见（M30 的教训）。
    ref.listenManual(hotkeysSuspendedProvider, (prev, next) {
      AppLogger.instance.info(
          'hotkey',
          next
              ? '热键设置页打开：本页在前台时忽略热键触发（注册保持有效）'
              : '热键设置页关闭：热键触发恢复');
    });
  }

  @override
  void dispose() {
    _hotkeyReloadTimer?.cancel();
    // 退出前显式注销热键：后台线程会回到 VM 线程池被复用，不注销就会留下
    // 旧注册（见 `services/hotkey_service.dart` 的类注释）。
    unawaited(_hotkey.dispose());
    _ball.dispose();
    coordinator.stagingListeners.remove(_setupTray);
    coordinator.stagingListeners.remove(_syncBallState);
    coordinator.busyListeners.remove(_syncBallState);
    coordinator.dispose();
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 「跟随系统」时要跟着 Windows 的深浅色切换。
  @override
  void didChangePlatformBrightness() => _applyWindowTheme();

  /// 窗口标题栏跟随应用主题（用户反馈 7 + 本轮「Windows 也没改」）。
  ///
  /// 注意不能用 `windowManager.setBrightness`：它在 Windows 端把「应用要深色」
  /// 和「系统当前是深色」做了 AND（见 `services/window_theme.dart` 的注释），
  /// 系统是浅色时永远是 no-op —— 这就是「切深色标题栏不变」的真凶。
  /// 这里直接调 DWM，只看应用主题。
  void _applyWindowTheme() {
    final app = ref.read(settingsProvider).app;
    final dark = switch (app.theme) {
      ThemeMode2.system =>
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
            Brightness.dark,
      ThemeMode2.light => false,
      ThemeMode2.dark => true,
    };
    final brightness = dark ? Brightness.dark : Brightness.light;
    final theme = QuizSyncTheme.build(
        brightness: brightness, accent: app.accent, fontFamily: 'MiSans');
    final hwnd = findAppWindow(kAppName);
    final applied = applyWindowChromeTheme(
      hwnd,
      brightness: brightness,
      caption: theme.appBarTheme.backgroundColor ?? theme.colorScheme.surface,
      text: theme.colorScheme.onSurface,
      border: QuizSyncTheme.outline(brightness),
    );
    AppLogger.instance.info('window',
        '标题栏主题：$brightness（应用 $applied 项，hwnd=$hwnd）');
  }

  Future<void> _setupTray() async {
    final status = ref.read(hotkeyStatusProvider);
    final capture = status[HotkeySlot.capture]?.activeLabel ?? '无可用热键';
    final append = status[HotkeySlot.append]?.activeLabel;
    final finish = status[HotkeySlot.finish]?.activeLabel;
    try {
      await trayManager.setIcon(await _trayIconPath());
      hotkeyTrace('tray icon set ok');
    } catch (e) {
      hotkeyTrace('tray setIcon FAILED: $e');
      AppLogger.instance.warn('tray', '图标加载失败：$e');
    }
    final staged = coordinator.stagedCount;
    final tip = staged > 0
        ? '$kAppName — $capture 截屏搜题 · 已暂存 $staged 页'
        : '$kAppName — $capture 截屏搜题';
    await trayManager.setToolTip(tip);
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'capture', label: '截取屏幕 ($capture)'),
      MenuItem(key: 'clipboard', label: '从剪贴板读取'),
      MenuItem.separator(),
      MenuItem(
          key: 'append',
          label: append == null ? '追加多页（热键被占用）' : '追加多页 ($append)'),
      MenuItem(
          key: 'finish',
          label: finish == null ? '结束多页（热键被占用）' : '结束多页并识别 ($finish)'),
      MenuItem(
          key: 'clear-staging',
          label: '清空多页暂存区（${coordinator.stagedCount} 页）'),
      MenuItem.separator(),
      MenuItem(key: 'collection', label: '切换任务合集…'),
      MenuItem(key: 'show', label: '显示主窗口'),
      MenuItem(key: 'settings', label: '设置'),
      MenuItem.separator(),
      MenuItem(key: 'exit', label: '退出'),
    ]));
    hotkeyTrace('tray menu set ok');
  }

  /// 托盘图标（用户反馈 8）：用 `icon/Statusbar.png` 生成的 `assets/statusbar.ico`，
  /// 与应用程序图标区分开。
  ///
  /// tray_manager 的 Windows 实现是 `LoadImage(..., LR_LOADFROMFILE)`：路径按
  /// **进程工作目录**解析，原来传的是 Flutter 资源键（`assets/...`），文件并不在
  /// 进程目录里，所以托盘一直是空白图标。这里先把资源落成数据目录下的真实文件，
  /// 再把**绝对路径**交给它。
  Future<String> _trayIconPath() async {
    final path = '${ref.read(dataRootProvider)}${Platform.pathSeparator}tray.ico';
    final file = File(path);
    final data = await rootBundle.load('assets/statusbar.ico');
    final bytes =
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    if (!file.existsSync() || file.lengthSync() != bytes.length) {
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
    }
    return path;
  }

  /// 注册全部槽位（用户反馈 6：重写热键注册；三个槽位都能自定义，
  /// 且自定义键支持物理键，失败时给出明确原因而不是静默回退）。
  Future<void> _setupHotkey() async {
    final log = StringBuffer();
    final app = ref.read(settingsProvider).app;
    final requests = <HotkeySlot, HotkeyCustomRequest>{};
    void addCustom(HotkeySlot slot, String? json) {
      if (json == null || json.isEmpty) return;
      try {
        final hk =
            HotKey.fromJson(jsonDecode(json) as Map<String, dynamic>);
        requests[slot] = HotkeyCustomRequest.of(hk, slot);
      } catch (e) {
        AppLogger.instance.warn('hotkey', '${slot.title} 自定义热键解析失败：$e');
      }
    }

    addCustom(HotkeySlot.capture, app.hotkeyJson);
    addCustom(HotkeySlot.append, app.appendHotkeyJson);
    addCustom(HotkeySlot.finish, app.finishHotkeyJson);

    final paused = _hotkeyBlocked();
    final statuses = await registerAllHotkeys(
      registrar: _hotkey,
      handlers: {
        HotkeySlot.capture: coordinator.captureAndAnalyze,
        HotkeySlot.append: coordinator.appendPage,
        HotkeySlot.finish: coordinator.finishMultiPage,
      },
      custom: requests,
      log: log,
      // M31：注册**永远**执行；「热键设置页正在前台」这种情形在触发那一刻才判断，
      // 所以状态永远是真实的，页面显示的键也就是真正注册着的键。
      blocked: _hotkeyBlocked,
      onBlocked: (m) => AppLogger.instance.info('hotkey', m),
    );
    ref.read(hotkeyStatusProvider.notifier).state = statuses;
    for (final s in statuses.values) {
      if (s.ok) {
        AppLogger.instance.info('hotkey', '${s.slot.title}：${s.message}');
      } else {
        AppLogger.instance.warn('hotkey', '${s.slot.title}：${s.message}');
      }
    }
    hotkeyTrace(log.toString());
    if (paused) {
      AppLogger.instance.info('hotkey',
          '本次注册时热键设置页正在前台：按键会被忽略（离开本页即恢复）');
    }
  }

  /// 热键触发要不要吞掉（M31）：**热键设置页挂载着**且**本窗口是前台窗口**。
  ///
  /// 两个条件缺一不可：
  /// - 页面没挂载 → 用户已经在别处，热键必须照常工作（M30 就是在这里锁死的）；
  /// - 本窗口不是前台 → 用户在别的程序 / 窗口收进了托盘或最小化了，
  ///   按热键必须照常截屏（这正是这个工具的主用法）。
  bool _hotkeyBlocked() =>
      ref.read(hotkeysSuspendedProvider) && appWindowIsForeground();

  void _syncClipboard() {
    coordinator
        .syncClipboardWatcher(ref.read(settingsProvider).app.clipboardWatch);
  }

  // ------------------------------------------------------------------
  // Windows 悬浮球（用户反馈 11）
  // ------------------------------------------------------------------

  /// 外观设置的指纹：只有这些字段变了才需要重画悬浮球。
  static String _ballSignature(AppSettings app) => ballSignature(app);

  /// 与安卓端一致的点击语义（Dart 侧决定，原生只上报手势）：
  /// 已经攒了页 → 单击 = 收尾识别；否则 = 单图识别。长按 = 追加一页。
  void _onBallTap() {
    if (coordinator.hasStaged) {
      unawaited(coordinator.finishMultiPage());
    } else {
      unawaited(coordinator.captureAndAnalyze());
    }
  }

  void _onBallLongPress() => unawaited(coordinator.appendPage());

  /// 状态图：识别中 > 多页模式 > 待识别。
  void _syncBallState() {
    final state = coordinator.busy
        ? BallState.detecting
        : (coordinator.hasStaged ? BallState.multiPage : BallState.idle);
    unawaited(_ball.setState(state));
  }

  /// 把设置里的悬浮球参数应用到窗口：开关 → 显示/隐藏，其余 → 重画。
  Future<void> _applyBallSettings() async {
    final app = ref.read(settingsProvider).app;
    await _ball.applyAppearance(
      sizePx: app.ballSize,
      opacity: app.ballOpacity,
      strokeEnabled: app.ballStroke,
      strokeWidth: app.ballStrokeWidth,
      strokeOpacity: app.ballStrokeOpacity,
    );
    if (app.ballEnabled) {
      _syncBallState();
      await _ball.show();
    } else {
      _ball.hide();
    }
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _openSettings() async {
    final ctx = _navigatorKey.currentContext;
    await _showWindow();
    if (ctx != null && ctx.mounted) {
      await Navigator.of(ctx).push(
          MaterialPageRoute(builder: (_) => const SettingsPage()));
    }
  }

  @override
  void onWindowClose() async {
    // 关闭主窗口 = 隐藏到托盘，不退出（SPEC 2.4）。
    await windowManager.hide();
  }

  @override
  void onTrayIconMouseDown() => _showWindow();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'capture':
        await coordinator.captureAndAnalyze();
        break;
      case 'clipboard':
        await coordinator.analyzeClipboardNow();
        break;
      case 'append':
        await coordinator.appendPage();
        break;
      case 'finish':
        await coordinator.finishMultiPage();
        break;
      case 'clear-staging':
        coordinator.clearStaging();
        break;
      case 'collection':
        await _showWindow();
        await _openCollectionPicker();
        break;
      case 'show':
        await _showWindow();
        break;
      case 'settings':
        await _openSettings();
        break;
      case 'exit':
        await ref.read(dbProvider).close();
        await windowManager.destroy();
        exit(0);
    }
  }

  /// 托盘「切换任务合集」（用户需求 8）。
  Future<void> _openCollectionPicker() async {
    final ctx = _navigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;
    await showCollectionPicker(ctx, ref);
  }

  @override
  Widget build(BuildContext context) {
    // 悬浮球在首帧之后再创建：分层窗口要在引擎起来之后才可靠。
    if (!_ballStarted) {
      _ballStarted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_applyBallSettings());
      });
    }
    return QuizSyncApp(coordinator: coordinator, navigatorKey: _navigatorKey);
  }
}
