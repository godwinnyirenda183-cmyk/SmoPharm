// Feature: pharmacy-pos, Property 6: Non-Negative Stock Invariant
//
// Validates: Requirements 4.2, 4.3
//
// Property 6: For any Stock_Adjustment with delta d applied to a product with
// Stock_Level S, if S + d < 0 the adjustment SHALL be rejected and the
// Stock_Level SHALL remain S. If S + d >= 0 the adjustment SHALL be accepted
// and the Stock_Level SHALL become S + d.

import 'package:drift/drift.dart' hide Batch;
import 'package:drift/native.dart';
import 'package:glados/glados.dart';
import 'package:pharmacy_pos/data/repositories/stock_adjustment_repository_impl.dart';
import 'package:pharmacy_pos/database/database.dart' as db_lib;
import 'package:pharmacy_pos/domain/entities/stock_adjustment.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

db_lib.AppDatabase _openTestDb() =>
    db_lib.AppDatabase.forTesting(NativeDatabase.memory());

/// Seeds a minimal user row (required by FK) and returns the user id.
Future<String> _insertUser(db_lib.AppDatabase db,
    {String id = 'user-1'}) async {
  await db.into(db.users).insert(db_lib.UsersCompanion.insert(
        id: id,
        username: 'pharmacist_$id',
        passwordHash: 'hash',
        role: 'admin',
      ));
  return id;
}

/// Seeds a minimal product row (required by FK) and returns the product id.
Future<String> _insertProduct(db_lib.AppDatabase db,
    {String id = 'prod-1'}) async {
  await db.into(db.products).insert(db_lib.ProductsCompanion.insert(
        id: id,
        name: 'Product $id',
        genericName: 'Generic $id',
        category: 'General',
        unitOfMeasure: 'Tablet',
        sellingPrice: 500,
        lowStockThreshold: 10,
      ));
  return id;
}

/// Inserts a non-expired batch with [quantity] units for [productId].
Future<void> _insertBatch(
  db_lib.AppDatabase db, {
  required String productId,
  required int quantity,
  String batchId = 'batch-1',
}) async {
  await db.into(db.batches).insert(db_lib.BatchesCompanion.insert(
        id: batchId,
        productId: productId,
        batchNumber: 'LOT-001',
        expiryDate: DateTime.now().add(const Duration(days: 365)),
        supplierName: 'Supplier',
        quantityReceived: quantity,
        quantityRemaining: quantity,
        costPricePerUnit: 100,
        status: const Value('active'),
      ));
}

/// Computes the current stock level for [productId] as the sum of
/// quantity_remaining across all non-expired batches.
Future<int> _stockLevel(db_lib.AppDatabase db, String productId) async {
  final batches = await (db.select(db.batches)
        ..where((b) =>
            b.productId.equals(productId) &
            b.status.isNotIn(const ['expired'])))
      .get();
  return batches.fold<int>(0, (sum, b) => sum + b.quantityRemaining);
}

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

/// Minimum 100 iterations as required by the testing strategy.
final _exploreConfig = ExploreConfig(numRuns: 100);

/// Generates an initial stock level S in [0, 500].
final _genInitialStock = any.intInRange(0, 501);

/// Generates a delta d in [-600, 500].
/// This range covers:
///   - Valid decreases (d in [-S, -1]) when S > 0
///   - Zero delta (d = 0)
///   - Positive increases (d in [1, 500])
///   - Invalid decreases that would go negative (d < -S)
final _genDelta = any.intInRange(-600, 501);

// ---------------------------------------------------------------------------
// Property tests
// ---------------------------------------------------------------------------

void main() {
  group('Property 6: Non-Negative Stock Invariant', () {
    // -------------------------------------------------------------------------
    // Acceptance property: for any S >= 0 and d where S + d >= 0,
    // the adjustment is accepted and stock level becomes S + d.
    //
    // Strategy:
    //   1. Generate initial stock level S in [0, 500].
    //   2. Generate delta d in [0, 500] (always valid since S >= 0 and d >= 0).
    //   3. Seed a product with initial stock S.
    //   4. Apply adjustment with delta d.
    //   5. Assert stock level == S + d.
    // -------------------------------------------------------------------------
    Glados2(_genInitialStock, any.intInRange(0, 501), _exploreConfig).test(
      'accepted when S + d >= 0: stock level becomes S + d',
      (initialStock, positiveDelta) async {
        final db = _openTestDb();
        try {
          final userId = await _insertUser(db);
          final productId = await _insertProduct(db);

          if (initialStock > 0) {
            await _insertBatch(db,
                productId: productId, quantity: initialStock);
          }

          final stockBefore = await _stockLevel(db, productId);
          expect(
            stockBefore,
            equals(initialStock),
            reason:
                'Pre-condition: initial stock level must equal $initialStock.',
          );

          final repo = StockAdjustmentRepositoryImpl(db);
          await repo.create(StockAdjustmentInput(
            productId: productId,
            userId: userId,
            quantityDelta: positiveDelta,
            reasonCode: AdjustmentReasonCode.countCorrection,
          ));

          final stockAfter = await _stockLevel(db, productId);
          expect(
            stockAfter,
            equals(initialStock + positiveDelta),
            reason:
                'Expected stock level ${initialStock + positiveDelta} '
                '(S=$initialStock + d=$positiveDelta) but got $stockAfter.',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Acceptance property for negative delta: for any S in [1, 500] and
    // d in [-S, -1], the adjustment is accepted (S + d >= 0) and stock level
    // becomes S + d.
    //
    // Strategy:
    //   1. Generate initial stock level S in [1, 500].
    //   2. Generate a fraction f in [0, 99] and compute d = -(f * S ~/ 100 + 1)
    //      so that d is always in [-S, -1] (valid: S + d in [0, S-1]).
    //   3. Seed a product with initial stock S.
    //   4. Apply adjustment with delta d.
    //   5. Assert stock level == S + d.
    // -------------------------------------------------------------------------
    Glados2(any.intInRange(1, 501), any.intInRange(0, 100), _exploreConfig).test(
      'accepted when S + d >= 0 with negative delta: stock level becomes S + d',
      (initialStock, fraction) async {
        // Compute a valid negative delta: d in [-initialStock, -1].
        // fraction in [0, 99] maps to d in [-initialStock, -1].
        final delta = -(fraction * initialStock ~/ 100 + 1);
        // Clamp to ensure d >= -initialStock (handles fraction=99 edge).
        final clampedDelta = delta < -initialStock ? -initialStock : delta;

        final db = _openTestDb();
        try {
          final userId = await _insertUser(db);
          final productId = await _insertProduct(db);

          await _insertBatch(db,
              productId: productId, quantity: initialStock);

          final repo = StockAdjustmentRepositoryImpl(db);
          await repo.create(StockAdjustmentInput(
            productId: productId,
            userId: userId,
            quantityDelta: clampedDelta,
            reasonCode: AdjustmentReasonCode.damaged,
          ));

          final stockAfter = await _stockLevel(db, productId);
          expect(
            stockAfter,
            equals(initialStock + clampedDelta),
            reason:
                'Expected stock level ${initialStock + clampedDelta} '
                '(S=$initialStock + d=$clampedDelta) but got $stockAfter.',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Rejection property: for any S >= 0 and d where S + d < 0,
    // the adjustment is rejected with StateError and stock level remains S.
    //
    // Strategy:
    //   1. Generate initial stock level S in [0, 500].
    //   2. Generate delta d in [-S-100, -S-1] (always invalid: S + d < 0).
    //   3. Seed a product with initial stock S.
    //   4. Attempt adjustment with delta d.
    //   5. Assert StateError is thrown.
    //   6. Assert stock level is still S.
    // -------------------------------------------------------------------------
    Glados(_genInitialStock, _exploreConfig).test(
      'rejected when S + d < 0: StateError thrown and stock level remains S',
      (initialStock) async {
        // Generate an invalid delta: -(initialStock + 1) always makes S + d = -1 < 0.
        final invalidDelta = -(initialStock + 1);

        final db = _openTestDb();
        try {
          final userId = await _insertUser(db);
          final productId = await _insertProduct(db);

          if (initialStock > 0) {
            await _insertBatch(db,
                productId: productId, quantity: initialStock);
          }

          final stockBefore = await _stockLevel(db, productId);
          expect(
            stockBefore,
            equals(initialStock),
            reason:
                'Pre-condition: initial stock level must equal $initialStock.',
          );

          final repo = StockAdjustmentRepositoryImpl(db);

          Object? caughtError;
          try {
            await repo.create(StockAdjustmentInput(
              productId: productId,
              userId: userId,
              quantityDelta: invalidDelta,
              reasonCode: AdjustmentReasonCode.damaged,
            ));
          } catch (e) {
            caughtError = e;
          }

          expect(
            caughtError,
            isA<StateError>(),
            reason:
                'Expected StateError for delta=$invalidDelta (S=$initialStock) '
                'but no error was thrown.',
          );

          // Stock level must be unchanged.
          final stockAfter = await _stockLevel(db, productId);
          expect(
            stockAfter,
            equals(stockBefore),
            reason:
                'Stock level must remain $stockBefore after a rejected adjustment '
                '(delta=$invalidDelta), but got $stockAfter.',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Boundary property: adjustment that brings stock to exactly zero is accepted.
    //
    // Strategy:
    //   1. Generate initial stock level S in [1, 500].
    //   2. Apply delta d = -S (exactly zeroes out stock).
    //   3. Assert stock level == 0.
    // -------------------------------------------------------------------------
    Glados(any.intInRange(1, 501), _exploreConfig).test(
      'adjustment to exactly zero is accepted: stock level becomes 0',
      (initialStock) async {
        final db = _openTestDb();
        try {
          final userId = await _insertUser(db);
          final productId = await _insertProduct(db);

          await _insertBatch(db,
              productId: productId, quantity: initialStock);

          final repo = StockAdjustmentRepositoryImpl(db);
          await repo.create(StockAdjustmentInput(
            productId: productId,
            userId: userId,
            quantityDelta: -initialStock,
            reasonCode: AdjustmentReasonCode.countCorrection,
          ));

          final stockAfter = await _stockLevel(db, productId);
          expect(
            stockAfter,
            equals(0),
            reason:
                'Expected stock level 0 after zeroing adjustment '
                '(S=$initialStock, d=${-initialStock}) but got $stockAfter.',
          );
        } finally {
          await db.close();
        }
      },
    );
  });
}
