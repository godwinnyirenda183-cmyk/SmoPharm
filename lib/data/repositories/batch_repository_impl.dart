import 'package:drift/drift.dart' hide Batch;
import 'package:pharmacy_pos/database/database.dart';
import 'package:pharmacy_pos/domain/entities/batch.dart';
import 'package:pharmacy_pos/domain/repositories/batch_repository.dart';
import 'package:uuid/uuid.dart';

/// Concrete implementation of [BatchRepository] backed by the Drift
/// [AppDatabase].
class BatchRepositoryImpl implements BatchRepository {
  final AppDatabase _db;
  final Uuid _uuid;

  BatchRepositoryImpl(this._db, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  // ---------------------------------------------------------------------------
  // create
  // ---------------------------------------------------------------------------

  @override
  Future<Batch> create(BatchInput input, {required int nearExpiryWindowDays}) async {
    final id = _uuid.v4();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final expiry = DateTime(
      input.expiryDate.year,
      input.expiryDate.month,
      input.expiryDate.day,
    );

    final status = _computeStatus(expiry, today, nearExpiryWindowDays);

    await _db.into(_db.batches).insert(
          BatchesCompanion.insert(
            id: id,
            productId: input.productId,
            batchNumber: input.batchNumber,
            expiryDate: input.expiryDate,
            supplierName: input.supplierName,
            quantityReceived: input.quantityReceived,
            quantityRemaining: input.quantityReceived,
            costPricePerUnit: input.costPricePerUnit,
            receivedDate: Value(now),
            status: Value(status),
          ),
        );

    return Batch(
      id: id,
      productId: input.productId,
      batchNumber: input.batchNumber,
      expiryDate: input.expiryDate,
      supplierName: input.supplierName,
      quantityReceived: input.quantityReceived,
      quantityRemaining: input.quantityReceived,
      costPricePerUnit: input.costPricePerUnit,
      receivedDate: now,
      status: _statusFromString(status),
    );
  }

  // ---------------------------------------------------------------------------
  // selectFEFO
  // ---------------------------------------------------------------------------

  @override
  Future<Batch?> selectFEFO(String productId, int quantityNeeded) async {
    final rows = await (_db.select(_db.batches)
          ..where(
            (b) =>
                b.productId.equals(productId) &
                b.status.isNotIn(const ['expired']) &
                b.quantityRemaining.isBiggerOrEqualValue(quantityNeeded),
          )
          ..orderBy([(b) => OrderingTerm.asc(b.expiryDate)])
          ..limit(1))
        .get();

    if (rows.isEmpty) return null;
    return _rowToEntity(rows.first);
  }

  // ---------------------------------------------------------------------------
  // nearExpiry
  // ---------------------------------------------------------------------------

  @override
  Future<List<Batch>> nearExpiry(int windowDays) async {
    final rows = await (_db.select(_db.batches)
          ..where((b) => b.status.equals('near_expiry')))
        .get();

    return rows.map(_rowToEntity).toList();
  }

  // ---------------------------------------------------------------------------
  // expiredBatches
  // ---------------------------------------------------------------------------

  @override
  Future<List<Batch>> expiredBatches() async {
    final rows = await (_db.select(_db.batches)
          ..where((b) => b.status.equals('expired')))
        .get();

    return rows.map(_rowToEntity).toList();
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Computes the batch status string from expiry date vs. today and window.
  String _computeStatus(DateTime expiry, DateTime today, int windowDays) {
    if (expiry.isBefore(today)) return 'expired';
    final windowEnd = today.add(Duration(days: windowDays));
    if (!expiry.isAfter(windowEnd)) return 'near_expiry';
    return 'active';
  }

  BatchStatus _statusFromString(String s) {
    switch (s) {
      case 'expired':
        return BatchStatus.expired;
      case 'near_expiry':
        return BatchStatus.nearExpiry;
      default:
        return BatchStatus.active;
    }
  }

  Batch _rowToEntity(Batche row) {
    return Batch(
      id: row.id,
      productId: row.productId,
      batchNumber: row.batchNumber,
      expiryDate: row.expiryDate,
      supplierName: row.supplierName,
      quantityReceived: row.quantityReceived,
      quantityRemaining: row.quantityRemaining,
      costPricePerUnit: row.costPricePerUnit,
      receivedDate: row.receivedDate,
      status: _statusFromString(row.status),
    );
  }
}
