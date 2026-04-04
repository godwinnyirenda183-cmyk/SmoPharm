import 'dart:convert';

import 'package:drift/drift.dart' hide Batch;
import 'package:pharmacy_pos/data/services/offline_queue_service.dart';
import 'package:pharmacy_pos/database/database.dart' as db_lib;
import 'package:pharmacy_pos/domain/entities/sale.dart';
import 'package:pharmacy_pos/domain/repositories/sale_repository.dart';
import 'package:uuid/uuid.dart';

/// Concrete implementation of [SaleRepository] backed by the Drift
/// [AppDatabase].
class SaleRepositoryImpl implements SaleRepository {
  final db_lib.AppDatabase _db;
  final Uuid _uuid;
  final OfflineQueueService _offlineQueue;

  SaleRepositoryImpl(this._db, {Uuid? uuid, OfflineQueueService? offlineQueue})
      : _uuid = uuid ?? const Uuid(),
        _offlineQueue = offlineQueue ?? OfflineQueueService(_db);

  // ---------------------------------------------------------------------------
  // create
  // ---------------------------------------------------------------------------

  @override
  Future<Sale> create(SaleInput input) async {
    return _db.transaction(() async {
      final saleId = _uuid.v4();
      final now = DateTime.now();

      final List<SaleItem> saleItems = [];

      for (final item in input.items) {
        // 1. Look up the product to get its name and selling price.
        final productRow = await (_db.select(_db.products)
              ..where((p) => p.id.equals(item.productId)))
            .getSingleOrNull();

        if (productRow == null) {
          throw StateError('Product not found: ${item.productId}');
        }

        // 2. Compute current stock level (sum of non-expired batch quantities).
        final batches = await _nonExpiredBatchesFEFO(item.productId);
        final stockLevel =
            batches.fold<int>(0, (sum, b) => sum + b.quantityRemaining);

        // 3. Reject if quantity exceeds stock level.
        if (item.quantity > stockLevel) {
          throw StateError(
              'Insufficient stock for ${productRow.name}');
        }

        // 4. FEFO batch selection: find the earliest-expiry batch with enough
        //    stock. We need to pick a single batch for the sale item record.
        final fefoRow = await _selectFEFO(item.productId, item.quantity);
        if (fefoRow == null) {
          throw StateError(
              'Insufficient stock for ${productRow.name}');
        }

        // 5. Decrement quantity_remaining on the selected batch.
        await (_db.update(_db.batches)
              ..where((b) => b.id.equals(fefoRow.id)))
            .write(db_lib.BatchesCompanion(
          quantityRemaining:
              Value(fefoRow.quantityRemaining - item.quantity),
        ));

        // 6. Calculate line total (integer cents).
        final unitPrice = productRow.sellingPrice;
        final lineTotal = item.quantity * unitPrice;

        // 7. Build SaleItem record.
        final saleItemId = _uuid.v4();
        saleItems.add(SaleItem(
          id: saleItemId,
          saleId: saleId,
          productId: item.productId,
          batchId: fefoRow.id,
          quantity: item.quantity,
          unitPrice: unitPrice,
          lineTotal: lineTotal,
        ));
      }

      // 8. Calculate total (sum of all line totals, integer cents).
      final totalZmw =
          saleItems.fold<int>(0, (sum, si) => sum + si.lineTotal);

      // 9. Insert Sale record.
      final paymentMethodStr = _paymentMethodToString(input.paymentMethod);
      await _db.into(_db.sales).insert(
            db_lib.SalesCompanion.insert(
              id: saleId,
              userId: input.userId,
              recordedAt: Value(now),
              totalZmw: totalZmw,
              paymentMethod: paymentMethodStr,
              voided: Value(false),
            ),
          );

      // 10. Insert SaleItem records.
      for (final si in saleItems) {
        await _db.into(_db.saleItems).insert(
              db_lib.SaleItemsCompanion.insert(
                id: si.id,
                saleId: saleId,
                productId: si.productId,
                batchId: si.batchId,
                quantity: si.quantity,
                unitPrice: si.unitPrice,
                lineTotal: si.lineTotal,
              ),
            );
      }

      final sale = Sale(
        id: saleId,
        userId: input.userId,
        recordedAt: now,
        totalZmw: totalZmw,
        paymentMethod: input.paymentMethod,
        voided: false,
        items: saleItems,
      );

      // 11. Enqueue for offline sync.
      await _offlineQueue.enqueue(
        entityType: 'sale',
        entityId: saleId,
        operation: 'INSERT',
        payloadJson: jsonEncode({
          'id': saleId,
          'userId': input.userId,
          'recordedAt': now.toIso8601String(),
          'totalZmw': totalZmw,
          'paymentMethod': paymentMethodStr,
          'voided': false,
          'items': saleItems
              .map((si) => {
                    'id': si.id,
                    'saleId': saleId,
                    'productId': si.productId,
                    'batchId': si.batchId,
                    'quantity': si.quantity,
                    'unitPrice': si.unitPrice,
                    'lineTotal': si.lineTotal,
                  })
              .toList(),
        }),
      );

      return sale;
    });
  }

  // ---------------------------------------------------------------------------
  // voidSale
  // ---------------------------------------------------------------------------

  @override
  Future<void> voidSale(String saleId, String reason) async {
    if (reason.trim().isEmpty) {
      throw ArgumentError('Void reason is required');
    }

    return _db.transaction(() async {
      // 1. Fetch the sale.
      final saleRow = await (_db.select(_db.sales)
            ..where((s) => s.id.equals(saleId)))
          .getSingleOrNull();

      if (saleRow == null) {
        throw StateError('Sale not found: $saleId');
      }

      // 2. Reject if already voided.
      if (saleRow.voided) {
        throw StateError('Sale is already voided');
      }

      // 3. Reject if not recorded on the current business day.
      final now = DateTime.now();
      final saleDate = saleRow.recordedAt;
      final sameDay = saleDate.year == now.year &&
          saleDate.month == now.month &&
          saleDate.day == now.day;
      if (!sameDay) {
        throw StateError(
            'Sales can only be voided on the day they were recorded');
      }

      // 4. Fetch all sale items.
      final items = await (_db.select(_db.saleItems)
            ..where((si) => si.saleId.equals(saleId)))
          .get();

      // 5. Restore stock: increment each batch's quantity_remaining.
      for (final item in items) {
        final batchRow = await (_db.select(_db.batches)
              ..where((b) => b.id.equals(item.batchId)))
            .getSingleOrNull();

        if (batchRow != null) {
          await (_db.update(_db.batches)
                ..where((b) => b.id.equals(item.batchId)))
              .write(db_lib.BatchesCompanion(
            quantityRemaining:
                Value(batchRow.quantityRemaining + item.quantity),
          ));
        }
      }

      // 6. Mark sale as voided.
      await (_db.update(_db.sales)..where((s) => s.id.equals(saleId)))
          .write(db_lib.SalesCompanion(
        voided: const Value(true),
        voidReason: Value(reason),
        voidedAt: Value(now),
      ));
    });
  }

  // ---------------------------------------------------------------------------
  // getSaleById
  // ---------------------------------------------------------------------------

  /// Returns the [Sale] with the given [saleId], or `null` if not found.
  Future<Sale?> getSaleById(String saleId) async {
    final saleRow = await (_db.select(_db.sales)
          ..where((s) => s.id.equals(saleId)))
        .getSingleOrNull();

    if (saleRow == null) return null;

    final itemRows = await (_db.select(_db.saleItems)
          ..where((si) => si.saleId.equals(saleId)))
        .get();

    final items = itemRows
        .map((r) => SaleItem(
              id: r.id,
              saleId: r.saleId,
              productId: r.productId,
              batchId: r.batchId,
              quantity: r.quantity,
              unitPrice: r.unitPrice,
              lineTotal: r.lineTotal,
            ))
        .toList();

    return Sale(
      id: saleRow.id,
      userId: saleRow.userId,
      recordedAt: saleRow.recordedAt,
      totalZmw: saleRow.totalZmw,
      paymentMethod: _paymentMethodFromString(saleRow.paymentMethod),
      voided: saleRow.voided,
      voidReason: saleRow.voidReason,
      voidedAt: saleRow.voidedAt,
      items: items,
    );
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

  /// Selects the earliest-expiry non-expired batch for [productId] that has
  /// at least [quantityNeeded] remaining (FEFO).
  Future<db_lib.Batche?> _selectFEFO(
      String productId, int quantityNeeded) async {
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

    return rows.isEmpty ? null : rows.first;
  }

  // ---------------------------------------------------------------------------
  // Mapping helpers
  // ---------------------------------------------------------------------------

  String _paymentMethodToString(PaymentMethod method) {
    switch (method) {
      case PaymentMethod.cash:
        return 'Cash';
      case PaymentMethod.mobileMoney:
        return 'Mobile_Money';
      case PaymentMethod.insurance:
        return 'Insurance';
    }
  }

  PaymentMethod _paymentMethodFromString(String value) {
    switch (value) {
      case 'Mobile_Money':
        return PaymentMethod.mobileMoney;
      case 'Insurance':
        return PaymentMethod.insurance;
      default:
        return PaymentMethod.cash;
    }
  }
}
