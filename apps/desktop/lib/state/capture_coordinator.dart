import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:quizsync_core/quizsync_core.dart';
import 'package:window_manager/window_manager.dart';

import '../services/clipboard_watcher.dart';
import '../services/screen_capture.dart';
import 'analysis_workflow.dart';
import 'app_scope.dart';
import '../ui/home_page.dart' show ensurePrivacyAcknowledged;

/// 采集协调器：热键 / 剪贴板 / 托盘 / 拖入粘贴 → 截图处理 → 工作流。
/// 平台相关（win32 / 托盘）；逻辑上只做「取字节 → 交给 workflow」。
class CaptureCoordinator {
  final WidgetRef Function() refOf;
  final BuildContext Function() contextOf;
  final ScreenCaptureService capture;
  final String imageDir;

  ClipboardWatcher? _clipboardWatcher;
  bool _busyFlag = false;

  /// 是否正在识别（用户反馈 11：悬浮球据此显示「识别中」状态图）。
  bool get busy => _busyFlag;

  /// 「正在识别」状态变化回调（悬浮球换状态图用）。
  final List<void Function()> busyListeners = [];

  set _busy(bool value) {
    if (_busyFlag == value) return;
    _busyFlag = value;
    for (final l in busyListeners) {
      try {
        l();
      } catch (_) {
        // 单个监听失败不影响主流程。
      }
    }
  }

  bool get _busy => _busyFlag;

  /// 多页暂存区（用户需求 4）：按下「追加页」热键把每一页放进这里等待上传，
  /// 到达上限或按下「截止」热键时一起送出。UI 据此显示「已暂存 N 页」。
  final List<WorkflowPage> _staged = [];

  /// 暂存页数变化回调（UI 显示进度条/提示）。
  void Function()? onStagingChanged;

  /// 额外的暂存变化监听（外壳用它刷新托盘提示；可以有多个，互不覆盖）。
  final List<void Function()> stagingListeners = [];

  /// 本次多页会话结束时的回调（结果 toast 之外的处理，如跳转会话）。
  void Function(String sessionId)? onSessionReady;

  CaptureCoordinator({
    required this.refOf,
    required this.contextOf,
    ScreenCaptureService? capture,
    required this.imageDir,
  }) : capture = capture ?? ScreenCaptureService();

  List<WorkflowPage> get stagedPages => List.unmodifiable(_staged);
  int get stagedCount => _staged.length;
  bool get hasStaged => _staged.isNotEmpty;

  /// 全局热键 / 托盘「截取屏幕」入口。
  ///
  /// 用户反馈 12：识别全程**后台静默**——不再主动把窗口弹到前台；
  /// 窗口本来就开着的话，SnackBar 照样能在窗口里看到。
  Future<void> captureAndAnalyze() async {
    if (_busy) {
      _toast('正在分析上一张，请稍候', reveal: true);
      return;
    }
    if (!await _guardPrivacy()) return;
    if (!await _guardCollection()) return;
    _busy = true;
    try {
      final shot = await _runCapture();
      if (shot == null) return;
      if (ImageProc.isAllBlack(shot.bgra, shot.width, shot.height)) {
        _toast('截屏内容为空白/黑图（该应用可能禁止截屏）');
        return;
      }
      final processed = ImageProc.toJpeg(shot.bgra, shot.width, shot.height);
      await _submit(
        jpeg: processed.jpeg,
        width: processed.width,
        height: processed.height,
        hash: sha256Hex(processed.jpeg),
        source: '屏幕截图',
      );
    } catch (e) {
      _toast('截屏失败：$e');
    } finally {
      _busy = false;
    }
  }

  // ============================================================
  // 多页识别（用户需求 4）
  // ============================================================

  /// 「追加页」热键：截一页放进暂存区；到达上限时提示并自动上传本次全部页。
  Future<void> appendPage() async {
    if (_busy) {
      _toast('正在识别上一组，请稍候再追加', reveal: true);
      return;
    }
    if (!await _guardPrivacy()) return;
    if (!await _guardCollection()) return;
    final limit = _multiPageLimit();
    if (_staged.length >= limit) {
      _toast('已达上限 $limit 页，正在上传本次全部页面');
      await submitStaged();
      return;
    }
    final page = await _capturePage();
    if (page == null) return;
    _staged.add(page);
    _notifyStaging();
    if (_staged.length >= limit) {
      _toast('已达上限 $limit 页，自动开始识别');
      await submitStaged();
      return;
    }
    _toast('已暂存第 ${_staged.length}/$limit 页'
        '（继续按可加页，按「结束多页」键上传本次全部页面）');
  }

  /// 「多页截止」热键：把当前屏幕作为**最后一页**截下并上传本次所有页面。
  Future<void> finishMultiPage() async {
    if (_busy) {
      _toast('正在识别上一组，请稍候', reveal: true);
      return;
    }
    if (!await _guardPrivacy()) return;
    if (!await _guardCollection()) return;
    final page = await _capturePage();
    if (page == null) return;
    _staged.add(page);
    _notifyStaging();
    await submitStaged();
  }

  /// 上传暂存区里的全部页面作为**一次识别**。
  Future<void> submitStaged() async {
    if (_staged.isEmpty) {
      _toast('暂存区是空的：先按「追加页」热键截图');
      return;
    }
    final pages = List<WorkflowPage>.from(_staged);
    _staged.clear();
    _notifyStaging();
    if (_busy) {
      _toast('正在识别上一组，本次 ${pages.length} 页已丢弃', reveal: true);
      return;
    }
    _busy = true;
    try {
      await _submitPages(pages, source: '多页截图');
    } catch (e) {
      _toast('分析失败：$e', reveal: true);
    } finally {
      _busy = false;
    }
  }

  /// 清空暂存区（用户取消本次多页）。
  void clearStaging() {
    if (_staged.isEmpty) return;
    _staged.clear();
    _notifyStaging();
    _toast('已清空多页暂存区');
  }

  void _notifyStaging() {
    onStagingChanged?.call();
    for (final l in stagingListeners) {
      try {
        l();
      } catch (_) {
        // 单个监听失败不影响其他监听与主流程。
      }
    }
  }

  int _multiPageLimit() {
    try {
      return refOf().read(settingsProvider).app.multiPageLimit;
    } catch (_) {
      return kDefaultMultiPageLimit;
    }
  }

  /// 截取一页（隐藏窗口 → 取帧 → 转 JPEG）。
  Future<WorkflowPage?> _capturePage() async {
    try {
      final shot = await _runCapture();
      if (shot == null) return null;
      if (ImageProc.isAllBlack(shot.bgra, shot.width, shot.height)) {
        _toast('截屏内容为空白/黑图（该应用可能禁止截屏）');
        return null;
      }
      final processed = ImageProc.toJpeg(shot.bgra, shot.width, shot.height);
      return WorkflowPage(
        jpeg: processed.jpeg,
        width: processed.width,
        height: processed.height,
        hash: sha256Hex(processed.jpeg),
      );
    } catch (e) {
      _toast('截屏失败：$e');
      return null;
    }
  }

  /// 剪贴板新图片回调。
  Future<void> onClipboardImage(CapturedImage image) async {
    if (_busy) {
      // 静默丢弃会让用户以为热键/剪贴板失效：明确提示。
      _toast('正在分析上一张，本次截图已忽略');
      return;
    }
    if (!await _guardPrivacy()) return;
    if (!await _guardCollection()) return;
    _busy = true;
    try {
      if (ImageProc.isAllBlack(image.bgra, image.width, image.height)) {
        return;
      }
      final processed =
          ImageProc.toJpeg(image.bgra, image.width, image.height);
      await _submit(
        jpeg: processed.jpeg,
        width: processed.width,
        height: processed.height,
        hash: sha256Hex(processed.jpeg),
        source: '剪贴板',
      );
    } catch (_) {
      // 静默：剪贴板路径不打扰用户。
    } finally {
      _busy = false;
    }
  }

  /// 托盘菜单「从剪贴板读取」：手动取一次当前剪贴板图片并分析。
  /// （剪贴板监听只管「新」图片，已在剪贴板里的内容不会触发。）
  Future<void> analyzeClipboardNow() async {
    CapturedImage? image;
    try {
      image = readClipboardImageNow();
    } catch (e) {
      _toast('读取剪贴板失败：$e', reveal: true);
      return;
    }
    if (image == null) {
      _toast('剪贴板里没有图片（可先截图或复制一张图）', reveal: true);
      return;
    }
    await onClipboardImage(image);
  }

  /// 主窗口粘贴（Ctrl+V）/ 拖入的图片字节。
  Future<void> analyzeBytes(Uint8List bytes, {String source = '图片文件'}) async {
    if (_busy) {
      _toast('正在分析上一张，请稍候', reveal: true);
      return;
    }
    if (!await _guardPrivacy()) return;
    if (!await _guardCollection()) return;
    _busy = true;
    try {
      // 已是 JPEG（常见情形）：直接按规则再压一遍统一规格。
      final decoded = decodeImage(bytes);
      if (decoded == null) {
        _toast('无法识别的图片格式');
        return;
      }
      final processed =
          ImageProc.toJpeg(decoded.bgra, decoded.width, decoded.height);
      await _submit(
        jpeg: processed.jpeg,
        width: processed.width,
        height: processed.height,
        hash: sha256Hex(processed.jpeg),
        source: source,
      );
    } catch (e) {
      _toast('分析失败：$e');
    } finally {
      _busy = false;
    }
  }

  Future<CapturedScreen?> _runCapture() async {
    // 截屏前隐藏主窗口（SPEC 2.1：不能把 UI 拍进图里）。
    return capture.hideWindowWhile(() => capture.captureCursorMonitor());
  }

  /// 单页入口：建会话 + 分析。
  Future<void> _submit({
    required Uint8List jpeg,
    required int width,
    required int height,
    required String hash,
    required String source,
  }) async {
    final ref = refOf();
    final settings = ref.read(settingsProvider);
    final apiKey = await ref.read(apiKeyReaderProvider)();
    if ((apiKey ?? '').isEmpty) {
      _toast('尚未配置 AI：请到设置页填写 API Key 与模型', reveal: true);
      return;
    }
    final dir = imageDir;
    final saveFiles = settings.app.saveImageFiles;

    final workflow = ref.read(workflowProvider);
    workflow.saveImageFile = saveFiles
        ? (h, bytes) async {
            final file = File('$dir/$h.jpg');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes);
            await ref.read(repoProvider).setImageLocalPath(h, file.path);
          }
        : null;
    workflow.readImageFile =
        saveFiles ? (h) async => File('$dir/$h.jpg').existsSync() ? await File('$dir/$h.jpg').readAsBytes() : null : null;
    final result = await workflow.run(
      jpeg: jpeg,
      imageHash: hash,
      width: width,
      height: height,
      config: AiConfig(
        providerId: settings.ai.providerId,
        baseUrl: settings.ai.baseUrl,
        apiKey: apiKey ?? '',
        model: settings.ai.model,
        timeoutSeconds: settings.ai.timeoutSeconds,
      ),
    );
    _toast(
        result.message ??
            (result.ok ? '$source：已出结果' : (result.errorMessage ?? '分析失败')),
        // M30（用户实测踩到）：本机识别保持静默，但**失败必须让用户看见** —— 热键明明
        // 生效了，却因为「截到的是聊天窗口 → no_question_found → SnackBar 只画在应用
        // 窗口里、而窗口在其他窗口后面」而看起来像「热键没反应」。
        reveal: !result.ok);
    if (result.ok && result.sessionId.isNotEmpty) {
      onSessionReady?.call(result.sessionId);
    }
    await _pruneCache(settings.app.imageCacheLimit);
    // 用量数字刷新（设置页的「今日用量」）。
    ref.invalidate(usageTodayProvider);
  }

  /// 多页入口（用户需求 4）：N 页作为一次识别。
  Future<void> _submitPages(List<WorkflowPage> pages,
      {required String source}) async {
    final ref = refOf();
    final settings = ref.read(settingsProvider);
    final apiKey = await ref.read(apiKeyReaderProvider)();
    if ((apiKey ?? '').isEmpty) {
      _toast('尚未配置 AI：请到设置页填写 API Key 与模型', reveal: true);
      return;
    }
    final dir = imageDir;
    final saveFiles = settings.app.saveImageFiles;
    final workflow = ref.read(workflowProvider);
    workflow.saveImageFile = saveFiles
        ? (h, bytes) async {
            final file = File('$dir/$h.jpg');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes);
            await ref.read(repoProvider).setImageLocalPath(h, file.path);
          }
        : null;
    workflow.readImageFile = saveFiles
        ? (h) async {
            final file = File('$dir/$h.jpg');
            if (!await file.exists()) return null;
            return file.readAsBytes();
          }
        : null;

    final result = await workflow.runMulti(
      pages: pages,
      config: AiConfig(
        providerId: settings.ai.providerId,
        baseUrl: settings.ai.baseUrl,
        apiKey: apiKey ?? '',
        model: settings.ai.model,
        timeoutSeconds: settings.ai.timeoutSeconds,
      ),
    );
    _toast(
        result.message ??
            (result.ok
                ? '$source：${pages.length} 页已出结果'
                : (result.errorMessage ?? '分析失败')),
        // 同单页路径：失败要把窗口带回来，否则热键生效了也像没反应。
        reveal: !result.ok);
    if (result.ok && result.sessionId.isNotEmpty) {
      onSessionReady?.call(result.sessionId);
    }
    await _pruneCache(settings.app.imageCacheLimit);
    ref.invalidate(usageTodayProvider);
  }

  /// 本地图片缓存上限（用户需求 5）：0 = 不设限。
  Future<void> _pruneCache(int limit) async {
    try {
      final dir = imageDir;
      await pruneImageFiles(
        refOf().read(repoProvider),
        (hash) => '$dir/$hash.jpg',
        maxFiles: limit,
        onDelete: (path) async {
          final file = File(path);
          if (await file.exists()) await file.delete();
        },
      );
    } catch (_) {
      // 清理失败不影响结果展示。
    }
  }

  /// 用户需求 8/12：没有选中合集就不允许开始任务（任务必须落在合集里）。
  Future<bool> _guardCollection() async {
    final ref = refOf();
    try {
      final id = await ref.read(repoProvider).getSetting(kActiveCollectionKey);
      if (id != null && id.isNotEmpty) {
        final c = await ref.read(repoProvider).getCollection(id);
        if (c != null) return true;
      }
    } catch (_) {
      // 读库失败按未选择处理。
    }
    _toast('请先新建或选择一个任务合集（左侧「切换合集」）', reveal: true);
    return false;
  }

  Future<bool> _guardPrivacy() async {
    final context = contextOf();
    final ref = refOf();
    return ensurePrivacyAcknowledged(context, ref);
  }

  /// 窗口隐藏到托盘时，隐私弹窗 / 结果 / 提示都发生在不可见的窗口里，
  /// 用户观感就是「热键没反应」——所有可见反馈前先把窗口带回来。
  Future<void> _reveal() async {
    try {
      if (!await windowManager.isVisible()) {
        await windowManager.show();
        await windowManager.focus();
      }
    } catch (_) {}
  }

  void _toast(String message, {bool reveal = false}) {
    // 只有「用户必须知道」的失败/前置条件才把窗口带回来（[reveal]）；
    // 正常识别流程保持后台静默（用户反馈 12）。
    if (reveal) _reveal();
    final context = contextOf();
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)));
  }

  /// 按设置启停剪贴板监听。
  void syncClipboardWatcher(bool enabled) {
    if (enabled) {
      _clipboardWatcher ??= ClipboardWatcher(onImage: onClipboardImage)
        ..start();
    } else {
      _clipboardWatcher?.stop();
      _clipboardWatcher = null;
    }
  }

  void dispose() {
    _clipboardWatcher?.stop();
  }
}

/// 解码任意图片字节到 BGRA（拖入文件 / 粘贴非 DIB 情形）。
class DecodedImage {
  final int width;
  final int height;
  final Uint8List bgra;
  DecodedImage(this.width, this.height, this.bgra);
}

DecodedImage? decodeImage(Uint8List bytes) {
  try {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    final bgra = decoded.getBytes(order: img.ChannelOrder.bgra);
    return DecodedImage(decoded.width, decoded.height, Uint8List.fromList(bgra));
  } catch (_) {
    return null;
  }
}
