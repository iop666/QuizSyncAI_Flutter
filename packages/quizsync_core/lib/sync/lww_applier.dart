import '../model/sync_op.dart';
import 'field_clocks.dart';

/// 字段级 LWW 应用结果。
class LwwResult {
  /// 实际被写入的字段名集合（被更新的写入跳过的不在内）。
  final Set<String> appliedFields;

  /// 应用后的字段时钟表（新 Map，不改入参）。
  final Map<String, FieldClock> clocks;

  /// 行级 lamport / updated_by：所有字段时钟中的最大值。
  final int rowLamport;
  final String rowUpdatedBy;

  const LwwResult(this.appliedFields, this.clocks, this.rowLamport, this.rowUpdatedBy);
}

/// 按 `data-model.md` 2.2 的伪码实现字段级 LWW。
///
/// [currentRow]：该实体当前行的字段值（snake_case 列名 → 值），
/// 含 `lamport` / `updated_by` 两个行级基准字段；行不存在时传 null。
/// 应用成功会把被接受字段直接写回 [currentRow]。
class LwwApplier {
  static LwwResult apply({
    Map<String, dynamic>? currentRow,
    required Map<String, FieldClock> clocks,
    required SyncOp op,
  }) {
    final applied = <String>{};
    final newClocks = Map<String, FieldClock>.from(clocks);

    // 字段从未被单独记录过时，以该行的 lamport / updated_by 作为基准比较，
    // 即「整体写入」与「字段写入」可以正确比较先后。
    final FieldClock? baseline = currentRow == null
        ? null
        : FieldClock(
            (currentRow['lamport'] as num?)?.toInt() ?? 0,
            currentRow['updated_by']?.toString() ?? '',
          );

    for (final entry in op.fields.entries) {
      final f = entry.key;
      final cur = newClocks[f] ?? baseline;
      if (cur != null &&
          compareVersions(op.lamport, op.deviceId, cur.l, cur.d) <= 0) {
        continue; // 已有更新的写入
      }
      if (currentRow != null) {
        currentRow[f] = entry.value;
      }
      newClocks[f] = FieldClock(op.lamport, op.deviceId);
      applied.add(f);
    }

    // 行级 lamport / updated_by 更新为所有字段时钟中的最大值。
    var rowLamport = (currentRow?['lamport'] as num?)?.toInt() ?? 0;
    var rowUpdatedBy = currentRow?['updated_by']?.toString() ?? '';
    for (final fc in newClocks.values) {
      if (compareVersions(fc.l, fc.d, rowLamport, rowUpdatedBy) > 0) {
        rowLamport = fc.l;
        rowUpdatedBy = fc.d;
      }
    }

    return LwwResult(applied, newClocks, rowLamport, rowUpdatedBy);
  }
}
