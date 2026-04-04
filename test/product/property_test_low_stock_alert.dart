// Feature: pharmacy-pos, Property 13: Low-Stock Alert Correctness
//
// Validates: Requirements 6.1, 6.2, 6.3, 7.3
//
// Property 13: For any product where stock_level <= low_stock_threshold, it
// SHALL appear in the low-stock alert list. For any product where
// stock_level > low_stock_threshold, it SHALL NOT appear in the list.

import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:glados/glados.dart';
// Hide Drift-generated Product to avoid conflict with domain entity.
import 'package:pharmacy_pos/database/database.dart' hide Product;
import 'package:pharmacy_pos/data/repositories/product_repository_impl.dart';
import 'package:pharmacy_pos/domain/entities/product.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

AppDatabase _openTestDb() => AppDatabase.forTesting(NativeDatabase.memory());

/// Creates a product with the given [lowStockThreshold] and returns it.
Future<Product> _seedProduct(
  ProductRepositoryImpl repo, {
  required String name,
  required int lowStockThreshold,
}) =>
    repo.create(ProductInput(
      name: name,
      genericName: '${name}Generic',
      category: 'General',
      unitOfMeasure: 'Tablet',
      sellingPrice: 500,
      lowStockThreshold: lowStockThreshold,
    ));

/// Inserts an active batch with [quantity] remaining for [productId].
Future<void> _addBatch(
  AppDatabase db,
  String productId,
  int quantity,
) async {
  await db.into(db.batches).insert(BatchesCompanion.insert(
        id: 'batch-${productId.hashCode}-$quantity-${DateTime.now().microsecondsSinceEpoch}',
        productId: productId,
        batchNumber: 'LOT-$quantity',
        expiryDate: DateTime(2030, 1, 1),
        supplierName: 'Supplier',
        quantityReceived: quantity,
        quantityRemaining: quantity,
        costPricePerUnit: 100,
        status: const Value('active'),
      ));
}

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

/// Minimum 100 iterations as required by the testing strategy.
final _exploreConfig = ExploreConfig(numRuns: 100);

/// Generates a stock level S in [0, 100].
final _genStockLevel = any.intInRange(0, 101); // 0 inclusive, 101 exclusive → [0, 100]

/// Generates a threshold T in [1, 100].
final _genThreshold = any.intInRange(1, 101); // 1 inclusive, 101 exclusive → [1, 100]

// ---------------------------------------------------------------------------
// Property tests
// ---------------------------------------------------------------------------

void main() {
  group('Property 13: Low-Stock Alert Correctness', () {
    // -------------------------------------------------------------------------
    // Sub-property A: Product with stock_level <= threshold appears in list
    //
    // For any stock level S in [0, 100] and threshold T in [1, 100] where
    // S <= T, the product SHALL appear in listLowStock().
    // -------------------------------------------------------------------------
    Glados2(_genStockLevel, _genThreshold, _exploreConfig).test(
      'product with stock_level <= threshold appears in low-stock list',
      (stockLevel, threshold) async {
        // Only test the case where stock_level <= threshold.
        if (stockLevel > threshold) return;

        final db = _openTestDb();
        try {
          final repo = ProductRepositoryImpl(db);

          final product = await _seedProduct(
            repo,
            name: 'LowStock-$stockLevel-$threshold',
            lowStockThreshold: threshold,
          );

          // Add a batch with the given stock level (skip if 0 — no batch means
          // stock = 0 which is already <= any positive threshold).
          if (stockLevel > 0) {
            await _addBatch(db, product.id, stockLevel);
          }

          final lowStockList = await repo.listLowStock();
          final ids = lowStockList.map((e) => e.product.id).toSet();

          expect(
            ids.contains(product.id),
            isTrue,
            reason:
                'Product with stock_level=$stockLevel and '
                'low_stock_threshold=$threshold should appear in the '
                'low-stock list (stock_level <= threshold), but it was absent.',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Sub-property B: Product with stock_level > threshold does NOT appear
    //
    // For any stock level S in [0, 100] and threshold T in [1, 100] where
    // S > T, the product SHALL NOT appear in listLowStock().
    // -------------------------------------------------------------------------
    Glados2(_genStockLevel, _genThreshold, _exploreConfig).test(
      'product with stock_level > threshold does NOT appear in low-stock list',
      (stockLevel, threshold) async {
        // Only test the case where stock_level > threshold.
        if (stockLevel <= threshold) return;

        final db = _openTestDb();
        try {
          final repo = ProductRepositoryImpl(db);

          final product = await _seedProduct(
            repo,
            name: 'OkStock-$stockLevel-$threshold',
            lowStockThreshold: threshold,
          );

          await _addBatch(db, product.id, stockLevel);

          final lowStockList = await repo.listLowStock();
          final ids = lowStockList.map((e) => e.product.id).toSet();

          expect(
            ids.contains(product.id),
            isFalse,
            reason:
                'Product with stock_level=$stockLevel and '
                'low_stock_threshold=$threshold should NOT appear in the '
                'low-stock list (stock_level > threshold), but it was present.',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Sub-property C: Boundary — stock_level == threshold appears in list
    //
    // The boundary condition (stock_level == threshold) is explicitly required
    // by Requirement 6.1: "at or below its Low_Stock_Threshold".
    // -------------------------------------------------------------------------
    Glados(_genThreshold, _exploreConfig).test(
      'product with stock_level == threshold appears in low-stock list',
      (threshold) async {
        final db = _openTestDb();
        try {
          final repo = ProductRepositoryImpl(db);

          final product = await _seedProduct(
            repo,
            name: 'Boundary-$threshold',
            lowStockThreshold: threshold,
          );

          // stock_level == threshold (exactly at the boundary).
          await _addBatch(db, product.id, threshold);

          final lowStockList = await repo.listLowStock();
          final ids = lowStockList.map((e) => e.product.id).toSet();

          expect(
            ids.contains(product.id),
            isTrue,
            reason:
                'Product with stock_level=threshold=$threshold should appear '
                'in the low-stock list (boundary: stock_level == threshold), '
                'but it was absent.',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Sub-property D: Mixed population — only low-stock products appear
    //
    // For any S and T, seed both a low-stock product (stock=S, threshold=T
    // where S <= T) and an ok-stock product (stock=T+1, threshold=T).
    // Only the low-stock product SHALL appear in the list.
    // -------------------------------------------------------------------------
    Glados2(_genStockLevel, _genThreshold, _exploreConfig).test(
      'only low-stock products appear when mixed population exists',
      (stockLevel, threshold) async {
        // Ensure we have a valid low-stock scenario: stockLevel <= threshold.
        final s = stockLevel <= threshold ? stockLevel : threshold;
        // The ok-stock product has stock = threshold + 1.
        final okStock = threshold + 1;

        final db = _openTestDb();
        try {
          final repo = ProductRepositoryImpl(db);

          // Low-stock product: stock=s, threshold=threshold → s <= threshold.
          final lowProduct = await _seedProduct(
            repo,
            name: 'Low-$s-$threshold',
            lowStockThreshold: threshold,
          );
          if (s > 0) {
            await _addBatch(db, lowProduct.id, s);
          }

          // Ok-stock product: stock=okStock, threshold=threshold → okStock > threshold.
          final okProduct = await _seedProduct(
            repo,
            name: 'Ok-$okStock-$threshold',
            lowStockThreshold: threshold,
          );
          await _addBatch(db, okProduct.id, okStock);

          final lowStockList = await repo.listLowStock();
          final ids = lowStockList.map((e) => e.product.id).toSet();

          expect(
            ids.contains(lowProduct.id),
            isTrue,
            reason:
                'Low-stock product (stock=$s, threshold=$threshold) should '
                'appear in the list but was absent.',
          );

          expect(
            ids.contains(okProduct.id),
            isFalse,
            reason:
                'Ok-stock product (stock=$okStock, threshold=$threshold) '
                'should NOT appear in the list but was present.',
          );
        } finally {
          await db.close();
        }
      },
    );
  });
}
