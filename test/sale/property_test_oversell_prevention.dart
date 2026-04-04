// Feature: pharmacy-pos, Property 10: Oversell Prevention
//
// Validates: Requirements 5.6
//
// Property 10: For any product with Stock_Level S and any sale item requesting
// quantity Q > S, the sale item SHALL be rejected and the Stock_Level SHALL
// remain unchanged.

import 'package:drift/drift.dart' hide Batch;
import 'package:drift/native.dart';
import 'package:glados/glados.dart';
import 'package:pharmacy_pos/data/repositories/sale_repository_impl.dart';
import 'package:pharmacy_pos/database/database.dart' as db_lib;
import 'package:pharmacy_pos/domain/entities/sale.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

db_lib.AppDatabase _openTestDb() =>
    db_lib.AppDatabase.forTesting(NativeDatabase.memory());

/// Insert a minimal user row (required by FK).
Future<String> _insertUser(db_lib.AppDatabase db, String suffix) async {
  final id = 'user-p10-$suffix';
  await db.into(db.users).insert(db_lib.UsersCompanion.insert(
        id: id,
        username: 'cashier_p10_$suffix',
        passwordHash: 'hash',
        role: 'cashier',
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
  int expiryDaysFromNow = 365,
}) async {
  await db.into(db.batches).insert(db_lib.BatchesCompanion.insert(
        id: batchId,
        productId: productId,
        batchNumber: 'LOT-$batchId',
        expiryDate: DateTime.now().add(Duration(days: expiryDaysFromNow)),
        supplierName: 'Supplier',
        quantityReceived: quantity,
        quantityRemaining: quantity,
        costPricePerUnit: 100,
        status: const Value('active'),
      ));
  return batchId;
}

/// Compute the current stock level for [productId] (sum of non-expired batches).
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

/// Generates stock level S in [0, 200].
/// Q is derived as S + 1 (always > S), so no separate generator is needed.
final _genStockLevel = any.intInRange(0, 201);

// ---------------------------------------------------------------------------
// Property tests
// ---------------------------------------------------------------------------

void main() {
  group('Property 10: Oversell Prevention', () {
    // -------------------------------------------------------------------------
    // Core property: sale is rejected when Q > S.
    //
    // Strategy:
    //   1. Generate stock level S in [0, 200].
    //   2. Set oversell quantity Q = S + 1 (always > S).
    //   3. Seed one product with a single non-expired batch of quantity S
    //      (or no batch at all when S == 0).
    //   4. Attempt to create a sale via SaleRepositoryImpl.create() for Q.
    //   5. Assert a StateError is thrown (sale rejected).
    // -------------------------------------------------------------------------
    Glados(_genStockLevel, _exploreConfig).test(
      'sale is rejected with StateError when quantity Q > stock level S',
      (s) async {
        final q = s + 1; // always oversells
        final db = _openTestDb();
        try {
          final repo = SaleRepositoryImpl(db);
          final userId = await _insertUser(db, 'reject');
          final productId = await _insertProduct(db, id: 'prod-p10-reject');

          if (s > 0) {
            await _insertBatch(db,
                batchId: 'batch-p10-reject',
                productId: productId,
                quantity: s);
          }

          await expectLater(
            repo.create(SaleInput(
              userId: userId,
              paymentMethod: PaymentMethod.cash,
              items: [SaleItemInput(productId: productId, quantity: q)],
            )),
            throwsA(isA<StateError>()),
            reason:
                'Expected StateError when selling Q=$q > S=$s, '
                'but no error was thrown.',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Stock unchanged property: after rejection, stock level remains S.
    //
    // Strategy:
    //   1. Generate stock level S in [0, 200].
    //   2. Set oversell quantity Q = S + 1.
    //   3. Seed one product with a batch of quantity S (or none if S == 0).
    //   4. Attempt the overselling sale (expect it to throw).
    //   5. Assert stock level is still S after the failed attempt.
    // -------------------------------------------------------------------------
    Glados(_genStockLevel, _exploreConfig).test(
      'stock level remains S after rejected oversell attempt',
      (s) async {
        final q = s + 1; // always oversells
        final db = _openTestDb();
        try {
          final repo = SaleRepositoryImpl(db);
          final userId = await _insertUser(db, 'unchanged');
          final productId = await _insertProduct(db, id: 'prod-p10-unchanged');

          if (s > 0) {
            await _insertBatch(db,
                batchId: 'batch-p10-unchanged',
                productId: productId,
                quantity: s);
          }

          // Attempt the overselling sale — it must throw.
          try {
            await repo.create(SaleInput(
              userId: userId,
              paymentMethod: PaymentMethod.cash,
              items: [SaleItemInput(productId: productId, quantity: q)],
            ));
          } on StateError {
            // Expected — sale was correctly rejected.
          }

          final after = await _stockLevel(db, productId);
          expect(
            after,
            equals(s),
            reason:
                'Stock level should remain $s after rejected oversell '
                '(Q=$q > S=$s), but got $after.',
          );
        } finally {
          await db.close();
        }
      },
    );
  });
}
