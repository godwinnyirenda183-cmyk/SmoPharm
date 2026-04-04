// Feature: pharmacy-pos, Property 9: Sale Decrements Stock
//
// Validates: Requirements 5.4
//
// Property 9: For any confirmed sale containing sale items, each affected
// product's Stock_Level SHALL decrease by exactly the sold quantity, using
// FEFO batch selection.

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
  final id = 'user-p9-$suffix';
  await db.into(db.users).insert(db_lib.UsersCompanion.insert(
        id: id,
        username: 'cashier_p9_$suffix',
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

/// Insert a batch for [productId] with [quantity] remaining and the given
/// [expiryDaysFromNow]. Returns the batch ID.
Future<String> _insertBatch(
  db_lib.AppDatabase db, {
  required String batchId,
  required String productId,
  required int quantity,
  required int expiryDaysFromNow,
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

/// Generates a pair (S, Q) where S is the initial stock in [1, 200] and
/// Q is the sold quantity in [1, S].
///
/// We bind S first, then generate Q in [1, S].
final _genStockAndSoldQty = any.intInRange(1, 201).bind(
  (s) => any.intInRange(1, s + 1).map((q) => (s, q)),
);

// ---------------------------------------------------------------------------
// Property tests
// ---------------------------------------------------------------------------

void main() {
  group('Property 9: Sale Decrements Stock', () {
    // -------------------------------------------------------------------------
    // Core property: stock level decreases by exactly the sold quantity.
    //
    // Strategy:
    //   1. Generate initial stock S in [1, 200] and sold quantity Q in [1, S].
    //   2. Seed one product with a single non-expired batch of quantity S.
    //   3. Record the stock level before the sale (should be S).
    //   4. Create a sale via SaleRepositoryImpl.create() for quantity Q.
    //   5. Assert stock level after == S - Q.
    // -------------------------------------------------------------------------
    Glados(_genStockAndSoldQty, _exploreConfig).test(
      'stock level decreases by exactly the sold quantity',
      (pair) async {
        final (s, q) = pair;
        final db = _openTestDb();
        try {
          final repo = SaleRepositoryImpl(db);
          final userId = await _insertUser(db, 'core');
          final productId = await _insertProduct(db, id: 'prod-p9-core');
          await _insertBatch(db,
              batchId: 'batch-p9-core',
              productId: productId,
              quantity: s,
              expiryDaysFromNow: 365);

          final before = await _stockLevel(db, productId);
          expect(before, equals(s),
              reason: 'Pre-condition: stock level should be $s but got $before');

          await repo.create(SaleInput(
            userId: userId,
            paymentMethod: PaymentMethod.cash,
            items: [SaleItemInput(productId: productId, quantity: q)],
          ));

          final after = await _stockLevel(db, productId);
          expect(
            after,
            equals(s - q),
            reason:
                'Stock level should be ${s - q} (S=$s - Q=$q) after sale, '
                'but got $after.',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // FEFO property: the earliest-expiry batch is decremented first.
    //
    // Strategy:
    //   1. Generate S in [1, 200] and Q in [1, S].
    //   2. Seed two batches for the same product:
    //      - earlyBatch: expiry in 30 days, quantity = S (sufficient for Q)
    //      - lateBatch:  expiry in 200 days, quantity = S
    //   3. Create a sale for quantity Q.
    //   4. Assert earlyBatch.quantityRemaining == S - Q (decremented).
    //   5. Assert lateBatch.quantityRemaining == S (untouched).
    // -------------------------------------------------------------------------
    Glados(_genStockAndSoldQty, _exploreConfig).test(
      'FEFO: earliest-expiry batch is decremented first',
      (pair) async {
        final (s, q) = pair;
        final db = _openTestDb();
        try {
          final repo = SaleRepositoryImpl(db);
          final userId = await _insertUser(db, 'fefo');
          final productId = await _insertProduct(db, id: 'prod-p9-fefo');

          // Early batch (should be selected by FEFO).
          await _insertBatch(db,
              batchId: 'batch-p9-early',
              productId: productId,
              quantity: s,
              expiryDaysFromNow: 30);

          // Late batch (should remain untouched).
          await _insertBatch(db,
              batchId: 'batch-p9-late',
              productId: productId,
              quantity: s,
              expiryDaysFromNow: 200);

          await repo.create(SaleInput(
            userId: userId,
            paymentMethod: PaymentMethod.cash,
            items: [SaleItemInput(productId: productId, quantity: q)],
          ));

          final earlyBatch = await (db.select(db.batches)
                ..where((b) => b.id.equals('batch-p9-early')))
              .getSingle();
          final lateBatch = await (db.select(db.batches)
                ..where((b) => b.id.equals('batch-p9-late')))
              .getSingle();

          expect(
            earlyBatch.quantityRemaining,
            equals(s - q),
            reason:
                'Early batch should be decremented by Q=$q '
                '(S=$s → ${s - q}) but got ${earlyBatch.quantityRemaining}.',
          );
          expect(
            lateBatch.quantityRemaining,
            equals(s),
            reason:
                'Late batch should be untouched (quantity=$s) '
                'but got ${lateBatch.quantityRemaining}.',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Persistence: batch quantity_remaining in the database reflects the
    // decrement after the sale.
    //
    // Strategy:
    //   1. Generate S in [1, 200] and Q in [1, S].
    //   2. Seed one product + batch with quantity S.
    //   3. Create a sale for Q.
    //   4. Read the batch row directly from the DB and assert
    //      quantityRemaining == S - Q.
    // -------------------------------------------------------------------------
    Glados(_genStockAndSoldQty, _exploreConfig).test(
      'batch quantity_remaining in DB equals S - Q after sale',
      (pair) async {
        final (s, q) = pair;
        final db = _openTestDb();
        try {
          final repo = SaleRepositoryImpl(db);
          final userId = await _insertUser(db, 'persist');
          final productId = await _insertProduct(db, id: 'prod-p9-persist');
          await _insertBatch(db,
              batchId: 'batch-p9-persist',
              productId: productId,
              quantity: s,
              expiryDaysFromNow: 365);

          await repo.create(SaleInput(
            userId: userId,
            paymentMethod: PaymentMethod.cash,
            items: [SaleItemInput(productId: productId, quantity: q)],
          ));

          final batchRow = await (db.select(db.batches)
                ..where((b) => b.id.equals('batch-p9-persist')))
              .getSingle();

          expect(
            batchRow.quantityRemaining,
            equals(s - q),
            reason:
                'Persisted quantityRemaining should be ${s - q} '
                '(S=$s - Q=$q) but got ${batchRow.quantityRemaining}.',
          );
        } finally {
          await db.close();
        }
      },
    );
  });
}
