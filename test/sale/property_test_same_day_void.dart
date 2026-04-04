// Feature: pharmacy-pos, Property 12: Same-Day Void Constraint
//
// Validates: Requirements 5.8
//
// Property 12: For any sale recorded on the current business day, voiding it
// SHALL succeed (for admin), restore all decremented stock quantities, and
// require a reason. For any sale recorded on a previous day, voiding SHALL
// be rejected.

import 'package:drift/drift.dart' hide Batch;
import 'package:drift/native.dart';
import 'package:glados/glados.dart';
import 'package:pharmacy_pos/data/repositories/sale_repository_impl.dart';
import 'package:pharmacy_pos/database/database.dart' as db_lib;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

db_lib.AppDatabase _openTestDb() =>
    db_lib.AppDatabase.forTesting(NativeDatabase.memory());

/// Insert a minimal user row (required by FK).
Future<String> _insertUser(db_lib.AppDatabase db, String suffix) async {
  final id = 'user-p12-$suffix';
  await db.into(db.users).insert(db_lib.UsersCompanion.insert(
        id: id,
        username: 'admin_p12_$suffix',
        passwordHash: 'hash',
        role: 'admin',
      ));
  return id;
}

/// Insert a product and return its ID.
Future<String> _insertProduct(
  db_lib.AppDatabase db, {
  required String id,
  int sellingPrice = 500,
}) async {
  await db.into(db.products).insert(db_lib.ProductsCompanion.insert(
        id: id,
        name: 'Drug-$id',
        genericName: 'Generic-$id',
        category: 'General',
        unitOfMeasure: 'Tablet',
        sellingPrice: sellingPrice,
        lowStockThreshold: 1,
      ));
  return id;
}

/// Insert a batch for [productId] with [quantity] remaining.
Future<String> _insertBatch(
  db_lib.AppDatabase db, {
  required String batchId,
  required String productId,
  required int quantity,
}) async {
  await db.into(db.batches).insert(db_lib.BatchesCompanion.insert(
        id: batchId,
        productId: productId,
        batchNumber: 'LOT-$batchId',
        expiryDate: DateTime.now().add(const Duration(days: 365)),
        supplierName: 'Supplier',
        quantityReceived: quantity,
        quantityRemaining: quantity,
        costPricePerUnit: 100,
        status: const Value('active'),
      ));
  return batchId;
}

/// Insert a sale row directly with a custom [recordedAt] timestamp.
Future<String> _insertSaleRow(
  db_lib.AppDatabase db, {
  required String userId,
  required DateTime recordedAt,
}) async {
  final saleId = 'sale-p12-${recordedAt.millisecondsSinceEpoch}';
  await db.into(db.sales).insert(db_lib.SalesCompanion.insert(
        id: saleId,
        userId: userId,
        recordedAt: Value(recordedAt),
        totalZmw: 500,
        paymentMethod: 'Cash',
        voided: const Value(false),
      ));
  return saleId;
}

/// Insert a sale item linking [saleId] to [batchId].
Future<void> _insertSaleItem(
  db_lib.AppDatabase db, {
  required String saleId,
  required String productId,
  required String batchId,
  required int quantity,
}) async {
  await db.into(db.saleItems).insert(db_lib.SaleItemsCompanion.insert(
        id: 'si-p12-${saleId.hashCode}-${batchId.hashCode}',
        saleId: saleId,
        productId: productId,
        batchId: batchId,
        quantity: quantity,
        unitPrice: 500,
        lineTotal: quantity * 500,
      ));
}

/// Returns the current [quantityRemaining] for [batchId].
Future<int> _batchQty(db_lib.AppDatabase db, String batchId) async {
  final row = await (db.select(db.batches)
        ..where((b) => b.id.equals(batchId)))
      .getSingle();
  return row.quantityRemaining;
}

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

/// Minimum 100 iterations as required by the testing strategy.
final _exploreConfig = ExploreConfig(numRuns: 100);

/// Generates a sold quantity in [1, 50].
final _genQty = any.intInRange(1, 51);

/// Generates a days-ago offset in [1, 365] for previous-day sales.
final _genDaysAgo = any.intInRange(1, 366);

// ---------------------------------------------------------------------------
// Property tests
// ---------------------------------------------------------------------------

void main() {
  group('Property 12: Same-Day Void Constraint', () {
    // -------------------------------------------------------------------------
    // Property A: voiding a same-day sale succeeds and stock is restored.
    //
    // Strategy:
    //   1. Generate sold quantity Q in [1, 50].
    //   2. Seed a product + batch with quantity Q (exactly enough).
    //   3. Insert a sale row with recordedAt = today, and a sale item for Q.
    //   4. Decrement the batch to simulate the sale having been applied.
    //   5. Call voidSale() with a non-empty reason.
    //   6. Assert no exception is thrown.
    //   7. Assert batch quantityRemaining is restored to Q.
    // -------------------------------------------------------------------------
    Glados(_genQty, _exploreConfig).test(
      'voiding a same-day sale succeeds and restores stock',
      (q) async {
        final db = _openTestDb();
        try {
          final repo = SaleRepositoryImpl(db);
          final userId = await _insertUser(db, 'same-$q');
          final productId = await _insertProduct(db, id: 'prod-p12-same-$q');
          final batchId = await _insertBatch(db,
              batchId: 'batch-p12-same-$q',
              productId: productId,
              quantity: q);

          // Insert sale recorded today.
          final today = DateTime.now();
          final saleId =
              await _insertSaleRow(db, userId: userId, recordedAt: today);
          await _insertSaleItem(db,
              saleId: saleId,
              productId: productId,
              batchId: batchId,
              quantity: q);

          // Simulate stock already decremented by the sale.
          await (db.update(db.batches)
                ..where((b) => b.id.equals(batchId)))
              .write(db_lib.BatchesCompanion(
                  quantityRemaining: Value(0)));

          // Void the sale — must succeed.
          await expectLater(
            repo.voidSale(saleId, 'Customer returned items'),
            completes,
            reason: 'voidSale should succeed for a same-day sale (Q=$q)',
          );

          // Stock must be restored.
          final restored = await _batchQty(db, batchId);
          expect(
            restored,
            equals(q),
            reason:
                'Batch quantity should be restored to $q after void, '
                'but got $restored.',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Property B: voiding a same-day sale requires a non-empty reason.
    //
    // Strategy:
    //   1. Generate sold quantity Q in [1, 50].
    //   2. Seed a product + batch + today's sale.
    //   3. Call voidSale() with an empty reason.
    //   4. Assert ArgumentError is thrown.
    // -------------------------------------------------------------------------
    Glados(_genQty, _exploreConfig).test(
      'voiding a same-day sale with empty reason throws ArgumentError',
      (q) async {
        final db = _openTestDb();
        try {
          final repo = SaleRepositoryImpl(db);
          final userId = await _insertUser(db, 'reason-$q');
          final productId =
              await _insertProduct(db, id: 'prod-p12-reason-$q');
          final batchId = await _insertBatch(db,
              batchId: 'batch-p12-reason-$q',
              productId: productId,
              quantity: q);

          final today = DateTime.now();
          final saleId =
              await _insertSaleRow(db, userId: userId, recordedAt: today);
          await _insertSaleItem(db,
              saleId: saleId,
              productId: productId,
              batchId: batchId,
              quantity: q);

          await expectLater(
            repo.voidSale(saleId, ''),
            throwsA(isA<ArgumentError>()),
            reason:
                'voidSale with empty reason should throw ArgumentError (Q=$q)',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Property C: voiding a previous-day sale is rejected with StateError.
    //
    // Strategy:
    //   1. Generate daysAgo in [1, 365].
    //   2. Seed a product + batch + sale recorded daysAgo days in the past.
    //   3. Call voidSale() with a valid reason.
    //   4. Assert StateError is thrown.
    // -------------------------------------------------------------------------
    Glados(_genDaysAgo, _exploreConfig).test(
      'voiding a previous-day sale throws StateError',
      (daysAgo) async {
        final db = _openTestDb();
        try {
          final repo = SaleRepositoryImpl(db);
          final userId = await _insertUser(db, 'prev-$daysAgo');
          final productId =
              await _insertProduct(db, id: 'prod-p12-prev-$daysAgo');
          final batchId = await _insertBatch(db,
              batchId: 'batch-p12-prev-$daysAgo',
              productId: productId,
              quantity: 10);

          final pastDate =
              DateTime.now().subtract(Duration(days: daysAgo));
          final saleId = await _insertSaleRow(db,
              userId: userId, recordedAt: pastDate);
          await _insertSaleItem(db,
              saleId: saleId,
              productId: productId,
              batchId: batchId,
              quantity: 5);

          await expectLater(
            repo.voidSale(saleId, 'Late void attempt'),
            throwsA(isA<StateError>()),
            reason:
                'voidSale should throw StateError for a sale recorded '
                '$daysAgo day(s) ago.',
          );
        } finally {
          await db.close();
        }
      },
    );
  });
}
