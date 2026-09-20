import 'package:quizsync_core/quizsync_core.dart';

/// 悬浮球外观（用户需求 11：透明度 / 大小）。
///
/// `AppSettings`（共享包）没有这两个字段，且共享包不由本端维护，
/// 所以用本地 settings 表存两份数值，不参与同步。
class BallAppearance {
  static const String opacityKey = 'ball_opacity';
  static const String sizeKey = 'ball_size_dp';

  static const double defaultOpacity = 0.85;
  static const double defaultSizeDp = 48;
  static const double minOpacity = 0.3;
  static const double maxOpacity = 1.0;
  static const double minSizeDp = 36;
  static const double maxSizeDp = 72;

  final double opacity;
  final double sizeDp;

  const BallAppearance({
    this.opacity = defaultOpacity,
    this.sizeDp = defaultSizeDp,
  });

  static Future<BallAppearance> load(CoreRepository repo) async {
    try {
      final o = double.tryParse(await repo.getSetting(opacityKey) ?? '');
      final s = double.tryParse(await repo.getSetting(sizeKey) ?? '');
      return BallAppearance(
        opacity: (o ?? defaultOpacity).clamp(minOpacity, maxOpacity),
        sizeDp: (s ?? defaultSizeDp).clamp(minSizeDp, maxSizeDp),
      );
    } catch (_) {
      return const BallAppearance();
    }
  }

  static Future<void> save(
    CoreRepository repo, {
    required double opacity,
    required double sizeDp,
  }) async {
    try {
      await repo.setSetting(opacityKey, opacity.toString());
      await repo.setSetting(sizeKey, sizeDp.toString());
    } catch (_) {
      // 存储不可用时不影响界面。
    }
  }
}
