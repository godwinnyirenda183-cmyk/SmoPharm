// Feature: pharmacy-pos, Property 1: Stock Level Equals Sum of Non-Expired Batch Quantities
//
// Validates: Requirements 1.4, 2.5, 3.1, 4.2
//
// Property 1: For any product with any set of batches, the computed Stock_Level
// SHALL equal the sum of quantity_remaining across all batches whose
// expiry_date >= today.

import 'package:drift/native.dart';
import 'package:glados/glados.dart';
import 'package:pharmacy_pos/data/repositories/batch_repository_impl.dart';
import 'package:pharmacy_pos/data/repositories/product_repository_impl.dart';
import 'package:pharmacy_pos/database/database.dart' hide Product;
import 'package:pharmacy_pos/domain/entities/batch.dart';
import 'package:pharmacy_pos/domain/entities/product.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

AppDatabase _openTestDb() => AppDatabase.forTesting(NativeDatabase.memory());

/// Seeds a single product and returns it.
Future<Product> _seedProduct(ProductRepositoryImpl repo, String suffix) =>
    repo.create(ProductInput(
      name: 'Product-$suffix',
      genericName: 'Generic-$suffix',
      category: 'General',
      unitOfMeasure: 'Tablet',
      sellingPrice: 500,
      lowStockThreshold: 10,
    ));

/// Inserts a batch for [productId] with the given [quantity] and [isExpired]
/// flag, returning the created [Batch].
Future<Batch> _insertBatch(
  BatchRepositoryImpl batchRepo,
  String productId,
  int quantity,
  bool isExpired,
  String batchNumber,
) {
  final today = DateTime.now();
  final expiryDate = isExpired
      ? today.subtract(const Duration(days: 1)) // yesterday → expired
      : today.add(const Duration(days: 200)); // far future → active

  return batchRepo.create(
    BatchInput(
      productId: productId,
      batchNumber: batchNumber,
      expiryDate: expiryDate,
      supplierName: 'Supplier',
      quantityReceived: quantity,
      costPricePerUnit: 100,
    ),
    nearExpiryWindowDays: 90,
  );
}

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

/// Minimum 100 iterations as required by the testing strategy.
final _exploreConfig = ExploreConfig(numRuns: 100);

/// Generates a positive quantity in [1, 200].
final _genQuantity = any.intInRange(1, 201);

/// Generates a list of 1–6 positive quantities.
final _genQuantityList = any.list(_genQuantity).map((list) {
  if (list.isEmpty) return [10];
  if (list.length > 6) return list.sublist(0, 6);
  return list;
});

/// Generates a list of booleans (expired flags) of length 1–6.
final _genExpiredList = any.list(any.bool).map((list) {
  if (list.isEmpty) return [false];
  if (list.length > 6) return list.sublist(0, 6);
  return list;
});

// ---------------------------------------------------------------------------
// Property tests
// ---------------------------------------------------------------------------

void main() {
  group('Property 1: Stock Level Equals Sum of Non-Expired Batch Quantities',
      () {
    // -------------------------------------------------------------------------
    // Core property: stock level = SUM(quantity_remaining) for non-expired
    // batches.
    //
    // Strategy:
    //   1. Generate a list of quantities and a list of expired flags.
    //   2. Zip them together (using the shorter list's length).
    //   3. Seed one product and insert all batches.
    //   4. Compute expected stock level = sum of quantities where !isExpired.
    //   5. Call ProductRepositoryImpl.listAll() and compare actual stock level.
    // -------------------------------------------------------------------------
    Glados2(_genQuantityList, _genExpiredList, _exploreConfig).test(
      'stock level equals sum of quantity_remaining for non-expired batches',
      (quantities, expiredFlags) async {
        // Zip quantities and expiredFlags using the shorter length.
        final count = quantities.length < expiredFlags.length
            ? quantities.length
            : expiredFlags.length;
        if (count == 0) return; // skip degenerate case

        final db = _openTestDb();
        try {
          final productRepo = ProductRepositoryImpl(db);
          final batchRepo = BatchRepositoryImpl(db);

          final product = await _seedProduct(productRepo, 'main');

          // Insert all batches.
          for (var i = 0; i < count; i++) {
            await _insertBatch(
              batchRepo,
              product.id,
              quantities[i],
              expiredFlags[i],
              'LOT-$i',
            );
          }

          // Compute expected stock level from the generated data.
          var expected = 0;
          for (var i = 0; i < count; i++) {
            if (!expiredFlags[i]) {
              expected += quantities[i];
            }
          }

          // Fetch actual stock level via ProductRepositoryImpl.listAll().
          final all = await productRepo.listAll();
          final match = all.firstWhere((p) => p.product.id == product.id);
          final actual = match.stockLevel;

          expect(
            actual,
            equals(expected),
            reason:
                'Expected stock level $expected (sum of non-expired quantities) '
                'but got $actual. '
                'quantities=$quantities, expiredFlags=$expiredFlags',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Edge case: all batches expired → stock level must be 0.
    // -------------------------------------------------------------------------
    Glados(_genQuantityList, _exploreConfig).test(
      'stock level is zero when all batches are expired',
      (quantities) async {
        final db = _openTestDb();
        try {
          final productRepo = ProductRepositoryImpl(db);
          final batchRepo = BatchRepositoryImpl(db);

          final product = await _seedProduct(productRepo, 'allexp');

          for (var i = 0; i < quantities.length; i++) {
            await _insertBatch(
              batchRepo,
              product.id,
              quantities[i],
              true, // all expired
              'EXP-$i',
            );
          }

          final all = await productRepo.listAll();
          final match = all.firstWhere((p) => p.product.id == product.id);

          expect(
            match.stockLevel,
            equals(0),
            reason:
                'All batches are expired so stock level must be 0, '
                'but got ${match.stockLevel}.',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Edge case: no batches → stock level must be 0.
    // -------------------------------------------------------------------------
    Glados(any.positiveInt, _exploreConfig).test(
      'stock level is zero when a product has no batches',
      (_) async {
        final db = _openTestDb();
        try {
          final productRepo = ProductRepositoryImpl(db);

          final product = await _seedProduct(productRepo, 'nobatch');

          final all = await productRepo.listAll();
          final match = all.firstWhere((p) => p.product.id == product.id);

          expect(
            match.stockLevel,
            equals(0),
            reason: 'Product with no batches must have stock level 0.',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Isolation: expired batches from one product do not affect another
    // product's stock level.
    // -------------------------------------------------------------------------
    Glados2(_genQuantityList, _genExpiredList, _exploreConfig).test(
      'expired batches from another product do not affect stock level',
      (quantities, expiredFlags) async {
        final count = quantities.length < expiredFlags.length
            ? quantities.length
            : expiredFlags.length;
        if (count == 0) return;

        final db = _openTestDb();
        try {
          final productRepo = ProductRepositoryImpl(db);
          final batchRepo = BatchRepositoryImpl(db);

          final productA = await _seedProduct(productRepo, 'A');
          final productB = await _seedProduct(productRepo, 'B');

          // Insert batches into product A.
          for (var i = 0; i < count; i++) {
            await _insertBatch(
              batchRepo,
              productA.id,
              quantities[i],
              expiredFlags[i],
              'A-LOT-$i',
            );
          }

          // Insert only an expired batch into product B.
          await _insertBatch(batchRepo, productB.id, 999, true, 'B-EXP');

          // Expected stock for product A.
          var expectedA = 0;
          for (var i = 0; i < count; i++) {
            if (!expiredFlags[i]) {
              expectedA += quantities[i];
            }
          }

          final all = await productRepo.listAll();
          final matchA = all.firstWhere((p) => p.product.id == productA.id);
          final matchB = all.firstWhere((p) => p.product.id == productB.id);

          expect(
            matchA.stockLevel,
            equals(expectedA),
            reason:
                'Product A stock level should be $expectedA but got ${matchA.stockLevel}.',
          );

          expect(
            matchB.stockLevel,
            equals(0),
            reason:
                'Product B has only expired batches; stock level must be 0 '
                'but got ${matchB.stockLevel}.',
          );
        } finally {
          await db.close();
        }
      },
    );
  });
}
