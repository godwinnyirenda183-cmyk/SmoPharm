import 'dart:convert';

import 'package:drift/drift.dart' hide Batch;
import 'package:pharmacy_pos/data/services/offline_queue_service.dart';
import 'package:pharmacy_pos/database/database.dart' as db_lib;
import 'package:pharmacy_pos/domain/entities/stock_adjustment.dart' as domain;
import 'package:pharmacy_pos/domain/repositories/stock_adjustment_repository.dart';
import 'package:uuid/uuid.dart';

/// Concrete implementation of [StockAdjustmentRepository] backed by the Drift
/// [AppDatabase].
///
/// Saved records are immutable — no update or delete operations are exposed.
class StockAdjustmentRepositoryImpl implements StockAdjustmentRepository {
  final db_lib.AppDatabase _db;
  final Uuid _uuid;
  final OfflineQueueService _offlineQueue;

  StockAdjustmentRepositoryImpl(this._db,
      {Uuid? uuid, OfflineQueueService? offlineQueue})
      : _uuid = uuid ?? const Uuid(),
        _offlineQueue = offlineQueue ?? OfflineQueueService(_db);

  // ---------------------------------------------------------------------------
  // create
  // ---------------------------------------------------------------------------

  @override
  Future<domain.StockAdjustment> create(
      domain.StockAdjustmentInput input) async {
    return _db.transaction(() async {
      // 1. Compute current stock level = SUM(quantity_remaining) over
      //    non-expired batches for the product.
      final batches = await _nonExpiredBatchesFEFO(input.productId);
      final currentStock =
          batches.fold<int>(0, (sum, b) => sum + b.quantityRemaining);

      // 2. Reject if resulting stock would be negative.
      if (currentStock + input.quantityDelta < 0) {
        throw StateError('Adjustment would result in negative stock');
      }

      // 3. Apply delta to batch quantities via FEFO order.
      await _applyDelta(batches, input.quantityDelta);

      // 4. Insert the StockAdjustment record.
      final id = _uuid.v4();
      final now = DateTime.now();
      final reasonStr = _reasonToString(input.reasonCode);

      await _db.into(_db.stockAdjustments).insert(
            db_lib.StockAdjustmentsCompanion.insert(
              id: id,
              productId: input.productId,
              userId: input.userId,
              quantityDelta: input.quantityDelta,
              reasonCode: reasonStr,
              recordedAt: Value(now),
            ),
          );

      final adjustment = domain.StockAdjustment(
        id: id,
        productId: input.productId,
        userId: input.userId,
        quantityDelta: input.quantityDelta,
        reasonCode: input.reasonCode,
        recordedAt: now,
      );

      // Enqueue for offline sync.
      await _offlineQueue.enqueue(
        entityType: 'stock_adjustment',
        entityId: id,
        operation: 'INSERT',
        payloadJson: jsonEncode({
          'id': id,
          'productId': input.productId,
          'userId': input.userId,
          'quantityDelta': input.quantityDelta,
          'reasonCode': reasonStr,
          'recordedAt': now.toIso8601String(),
        }),
      );

      return adjustment;
    });
  }

  // ---------------------------------------------------------------------------
  // listForProduct
  // ---------------------------------------------------------------------------

  @override
  Future<List<domain.StockAdjustment>> listForProduct(
      String productId) async {
    final rows = await (_db.select(_db.stockAdjustments)
          ..where((a) => a.productId.equals(productId))
          ..orderBy([(a) => OrderingTerm.asc(a.recordedAt)]))
        .get();

    return rows.map(_rowToEntity).toList();
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Returns non-expired batches for [productId] ordered by expiry date (FEFO).
  Future<List<db_lib.Batche>> _nonExpiredBatchesFEFO(
      String productId) async {
    return (_db.select(_db.batches)
          ..where(
            (b) =>
                b.productId.equals(productId) &
                b.status.isNotIn(const ['expired']),
          )
          ..orderBy([(b) => OrderingTerm.asc(b.expiryDate)]))
        .get();
  }

  /// Applies [delta] to batch quantities in FEFO order.
  ///
  /// - Negative delta: reduce quantity_remaining from earliest-expiry batches
  ///   first.
  /// - Positive delta: add to the first (earliest-expiry) non-expired batch.
  ///   If no batches exist, the delta cannot be applied to any batch row
  ///   (the adjustment record still captures the intent).
  Future<void> _applyDelta(List<db_lib.Batche> batches, int delta) async {
    if (delta == 0 || batches.isEmpty) return;

    if (delta > 0) {
      // Add to the first (earliest-expiry) non-expired batch.
      final first = batches.first;
      await (_db.update(_db.batches)..where((b) => b.id.equals(first.id)))
          .write(db_lib.BatchesCompanion(
        quantityRemaining: Value(first.quantityRemaining + delta),
      ));
    } else {
      // Subtract from batches in FEFO order.
      int remaining = -delta; // positive amount to subtract
      for (final batch in batches) {
        if (remaining <= 0) break;
        final take = remaining <= batch.quantityRemaining
            ? remaining
            : batch.quantityRemaining;
        await (_db.update(_db.batches)..where((b) => b.id.equals(batch.id)))
            .write(db_lib.BatchesCompanion(
          quantityRemaining: Value(batch.quantityRemaining - take),
        ));
        remaining -= take;
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Mapping helpers
  // ---------------------------------------------------------------------------

  String _reasonToString(domain.AdjustmentReasonCode code) {
    switch (code) {
      case domain.AdjustmentReasonCode.damaged:
        return 'Damaged';
      case domain.AdjustmentReasonCode.expiredRemoval:
        return 'Expired_Removal';
      case domain.AdjustmentReasonCode.countCorrection:
        return 'Count_Correction';
      case domain.AdjustmentReasonCode.other:
        return 'Other';
    }
  }

  domain.AdjustmentReasonCode _reasonFromString(String s) {
    switch (s) {
      case 'Damaged':
        return domain.AdjustmentReasonCode.damaged;
      case 'Expired_Removal':
        return domain.AdjustmentReasonCode.expiredRemoval;
      case 'Count_Correction':
        return domain.AdjustmentReasonCode.countCorrection;
      default:
        return domain.AdjustmentReasonCode.other;
    }
  }

  domain.StockAdjustment _rowToEntity(db_lib.StockAdjustment row) {
    return domain.StockAdjustment(
      id: row.id,
      productId: row.productId,
      userId: row.userId,
      quantityDelta: row.quantityDelta,
      reasonCode: _reasonFromString(row.reasonCode),
      recordedAt: row.recordedAt,
    );
  }
}
