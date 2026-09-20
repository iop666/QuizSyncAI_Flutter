import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:quizsync_core/quizsync_core.dart' show AppLogger;

import 'hotkeys.dart';

/// 诊断追踪：统一进应用日志（导出日志时可见）。
void hotkeyTrace(String line) => AppLogger.instance.info('hotkey', line);

/// 全局热键：**一个**后台 isolate（= 一个线程）里
/// `RegisterHotKey(NULL, id, mods, vk)` + `PeekMessageW` 轮询泵，
/// 每个用途一个固定 id。
///
/// ## 为什么必须是「一个 isolate + 固定 id + 显式注销」
///
/// M11 的实现是「每个槽位各起一个 isolate，id 一律写 1」，靠 isolate 退出
/// （线程退出）**隐式**释放注册。这在 Windows 上是错的：
///
/// 1. `RegisterHotKey(NULL, id, ...)` 把热键绑在**线程**的消息队列上；
/// 2. Dart 的 isolate 线程会回到 VM 线程池被**复用**，isolate 退出 ≠ 线程退出，
///    于是旧注册跟着线程活了下来；
/// 3. 下一轮注册时新 isolate 可能正好落在那个线程上：
///    - 注册同一个 id/vk 失败 → 被判成「被其他程序占用」而回退到别的键
///      （用户看到「改了热键不生效 / 多页热键改完没用」）；
///    - 而**旧注册仍然生效**，它触发的 WM_HOTKEY 落在同一个线程队列上，
///      被「现在跑在这个线程上的另一个槽位」的轮询泵读走 →
///      **按下截图键执行了「添加页面」，按下添加页面键却直接开始识别**。
///
/// 所以这里：所有热键共用一个长期存活的 isolate（线程不再被换手）、
/// 每个槽位一个稳定且互不相同的 id（`capture=1 / append=2 / finish=3`）、
/// 每次注册前先 `UnregisterHotKey` 同 id，退出时再显式注销全部。
class HotkeyService implements HotkeyRegistrar {
  static const int _kRegister = 1;
  static const int _kUnregister = 2;
  static const int _kQuit = 3;
  static const int _kReply = 10;
  static const int _kFired = 11;

  SendPort? _commands;
  ReceivePort? _events;
  Future<SendPort>? _starting;

  /// 热键 id → 触发回调（由主 isolate 持有，isolate 只回传 id）。
  final Map<int, void Function()> _handlers = {};

  /// 槽位名 → 热键 id（一旦分配就不变）。
  final Map<String, int> _idOfSlot = {};

  /// 热键 id → 当前生效键的标签（给设置页显示）。
  final Map<int, String> _labelOfId = {};

  /// isolate 侧当前真正注册着的 id。
  final Set<int> _registered = {};

  final Map<int, Completer<bool>> _pending = {};
  int _nextSlotId = 1;
  int _nextRequestId = 1;

  /// 某个 slot 当前生效的组合键标签；null = 没注册上。
  String? activeLabel(String slot) {
    final id = _idOfSlot[slot];
    return id == null ? null : _labelOfId[id];
  }

  /// 注册组合键。成功返回 true 并在每次按下时回调 [onTrigger]。
  /// [slot] 区分不同用途的热键（'capture' / 'append' / 'finish'）。
  @override
  Future<bool> register({
    required String slot,
    required int vk,
    required int nativeModifiers,
    required String label,
    required void Function() onTrigger,
  }) async {
    await unregister(slot: slot);
    final SendPort commands;
    try {
      commands = await _ensureIsolate();
    } catch (e) {
      hotkeyTrace('register[$slot] 后台线程启动失败：$e');
      return false;
    }
    final id = _idOfSlot.putIfAbsent(slot, () => _nextSlotId++);
    final reqId = _nextRequestId++;
    final done = Completer<bool>();
    _pending[reqId] = done;
    commands.send(<dynamic>[_kRegister, reqId, id, vk, nativeModifiers]);
    final ok = await done.future
        .timeout(const Duration(seconds: 2), onTimeout: () => false);
    _pending.remove(reqId);
    hotkeyTrace('register[$slot] id=$id vk=$vk mods=$nativeModifiers -> $ok');
    if (!ok) return false;
    _handlers[id] = onTrigger;
    _labelOfId[id] = label;
    _registered.add(id);
    return true;
  }

  /// 注销热键（[slot] 为 null 时注销全部）。
  ///
  /// 命令按发送顺序在 isolate 里串行执行，所以调用方紧接着 register 同一槽位
  /// 不会出现「先注册后被旧注销掉」的竞态。
  @override
  Future<void> unregister({String? slot}) async {
    final commands = _commands;
    if (commands == null) return;
    if (slot == null) {
      for (final id in _registered.toList()) {
        commands.send(<dynamic>[_kUnregister, 0, id]);
      }
      _handlers.clear();
      _labelOfId.clear();
      _registered.clear();
      return;
    }
    final id = _idOfSlot[slot];
    if (id == null) return;
    commands.send(<dynamic>[_kUnregister, 0, id]);
    _handlers.remove(id);
    _labelOfId.remove(id);
    _registered.remove(id);
  }

  /// 彻底停掉后台线程（退出程序时用；线程退出前会显式注销全部热键）。
  Future<void> dispose() async {
    final commands = _commands;
    _commands = null;
    _starting = null;
    _handlers.clear();
    _labelOfId.clear();
    _registered.clear();
    _pending.clear();
    _events?.close();
    _events = null;
    commands?.send(<dynamic>[_kQuit]);
  }

  Future<SendPort> _ensureIsolate() {
    final ready = _commands;
    if (ready != null) return Future.value(ready);
    return _starting ??= _start();
  }

  Future<SendPort> _start() async {
    final events = ReceivePort();
    final handshake = Completer<SendPort>();
    events.listen((raw) {
      // 第一条消息是 isolate 的命令端口，之后都是回复/事件。
      if (raw is SendPort) {
        if (!handshake.isCompleted) handshake.complete(raw);
        return;
      }
      _onMessage(raw);
    });
    try {
      await Isolate.spawn(_loop, events.sendPort);
      final commands = await handshake.future
          .timeout(const Duration(seconds: 3));
      _events = events;
      _commands = commands;
      return commands;
    } catch (e) {
      events.close();
      _events = null;
      _commands = null;
      rethrow;
    }
  }

  void _onMessage(dynamic raw) {
    if (raw is! List || raw.isEmpty) return;
    switch (raw[0]) {
      case _kFired:
        final id = raw[1];
        if (id is int) _handlers[id]?.call();
      case _kReply:
        final reqId = raw[1];
        if (reqId is int) {
          _pending.remove(reqId)?.complete(raw[2] == true);
        }
    }
  }
}

void _loop(SendPort toMain) async {
  final user32 = DynamicLibrary.open('user32.dll');
  final registerHotKey = user32.lookupFunction<
      Int32 Function(IntPtr, Int32, Uint32, Uint32),
      int Function(int, int, int, int)>('RegisterHotKey');
  final unregisterHotKey =
      user32.lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>(
          'UnregisterHotKey');
  final peekMessage = user32.lookupFunction<
      Int32 Function(Pointer<MSG>, IntPtr, Uint32, Uint32, Uint32),
      int Function(Pointer<MSG>, int, int, int, int)>('PeekMessageW');

  const wmHotkey = 0x0312;
  const pmRemove = 0x0001;

  final commands = ReceivePort();
  toMain.send(commands.sendPort);

  final registered = <int>{};
  var quit = false;
  commands.listen((raw) {
    if (raw is! List || raw.isEmpty) return;
    switch (raw[0]) {
      case HotkeyService._kRegister:
        final reqId = raw[1] as int;
        final id = raw[2] as int;
        final vk = raw[3] as int;
        final mods = raw[4] as int;
        // 先显式注销同 id 的旧注册：RegisterHotKey 不会替你替换
        // 「同线程 + 同 id + 不同键」的旧注册，直接注册会失败。
        unregisterHotKey(0, id);
        registered.remove(id);
        // id 用槽位的稳定编号，hwnd=NULL → WM_HOTKEY 投递到本线程消息队列。
        final ok = registerHotKey(0, id, mods, vk) != 0;
        if (ok) registered.add(id);
        toMain.send(<dynamic>[HotkeyService._kReply, reqId, ok]);
      case HotkeyService._kUnregister:
        final id = raw[2] as int;
        unregisterHotKey(0, id);
        registered.remove(id);
      case HotkeyService._kQuit:
        quit = true;
    }
  });

  final msg = calloc<MSG>();
  // 不能用阻塞的 GetMessageW：本 isolate 只有一个线程，阻塞在里面就永远收不到
  // 'quit'，注销与退出都不会生效。改为 PeekMessageW + await 让出事件循环。
  while (!quit) {
    var has = peekMessage(msg, 0, 0, 0, pmRemove);
    while (has != 0) {
      if (msg.ref.message == wmHotkey && registered.contains(msg.ref.wParam)) {
        toMain.send(<dynamic>[HotkeyService._kFired, msg.ref.wParam]);
      }
      has = peekMessage(msg, 0, 0, 0, pmRemove);
    }
    if (quit) break;
    await Future<void>.delayed(const Duration(milliseconds: 15));
  }
  // 退出前**显式**注销：线程会回到 VM 线程池被复用，不注销的话旧注册会跟着
  // 线程活下来，下一轮注册就会串键（见类注释）。
  for (final id in registered) {
    unregisterHotKey(0, id);
  }
  registered.clear();
  commands.close();
  calloc.free(msg);
}

/// Win32 MSG（x64，48 字节）。Dart FFI Struct 默认 packed，必须手工补
/// 对齐字段，否则 GetMessageW 写越界且 wParam 错位。
final class MSG extends Struct {
  @IntPtr()
  external int hwnd;
  @Uint32()
  external int message;
  @Uint32()
  external int pad1; // 4 字节对齐，使 wParam 落在 8 倍数偏移
  @IntPtr()
  external int wParam;
  @IntPtr()
  external int lParam;
  @Uint32()
  external int time;
  @Uint32()
  external int pad2;
  @IntPtr()
  external int pt; // POINT（两个 LONG）合为一个 8 字节成员
}
