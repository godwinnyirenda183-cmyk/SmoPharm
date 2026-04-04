// Feature: pharmacy-pos, Property 14: Low-Stock List Sort Order
//
// Validates: Requirements 6.4, 7.3
//
// Property 14: For any low-stock list, for every pair of adjacent items (a, b),
// the ratio a.stock_level / a.low_stock_threshold SHALL be less than or equal
// to b.stock_level / b.low_stock_threshold.

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
// Data class for a generated product spec
// ---------------------------------------------------------------------------

class _ProductSpec {
  final int stockLevel;
  final int threshold;

  const _ProductSpec(this.stockLevel, this.threshold);

  @override
  String toString() => '_ProductSpec(stock=$stockLevel, threshold=$threshold)';
}

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

/// Minimum 100 iterations as required by the testing strategy.
final _exploreConfig = ExploreConfig(numRuns: 100);

/// Generates a single low-stock product spec: threshold in [1, 50],
/// stockLevel in [0, threshold] (ensures stock_level <= threshold).
final _genLowStockSpec = any.intInRange(1, 51).bind(
  (threshold) => any.intInRange(0, threshold + 1).map(
    (stock) => _ProductSpec(stock, threshold),
  ),
);

/// Generates a list of 2–5 low-stock product specs.
final _genLowStockSpecList = any.list(_genLowStockSpec).map((list) {
  if (list.length < 2) return [const _ProductSpec(0, 1), const _ProductSpec(1, 2)];
  if (list.length > 5) return list.sublist(0, 5);
  return list;
});

// ---------------------------------------------------------------------------
// Property tests
// ---------------------------------------------------------------------------

void main() {
  group('Property 14: Low-Stock List Sort Order', () {
    // -------------------------------------------------------------------------
    // Main property: for every adjacent pair (a, b) in the returned list,
    // ratio_a <= ratio_b (ascending sort by stock_level / low_stock_threshold).
    //
    // Strategy:
    //   1. Generate a list of 2–5 product specs where each stock <= threshold.
    //   2. Seed all products into the database.
    //   3. Call listLowStock().
    //   4. For every adjacent pair (a, b), assert ratio_a <= ratio_b.
    // -------------------------------------------------------------------------
    Glados(_genLowStockSpecList, _exploreConfig).test(
      'adjacent items in low-stock list satisfy ratio_a <= ratio_b',
      (specs) async {
        final db = _openTestDb();
        try {
          final repo = ProductRepositoryImpl(db);

          // Seed each product spec into the database.
          for (var i = 0; i < specs.length; i++) {
            final spec = specs[i];
            final product = await _seedProduct(
              repo,
              name: 'Product-$i-${spec.stockLevel}-${spec.threshold}',
              lowStockThreshold: spec.threshold,
            );

            // Add a batch with the given stock level (skip if 0 — no batch
            // means stock = 0 which is already <= any positive threshold).
            if (spec.stockLevel > 0) {
              await _addBatch(db, product.id, spec.stockLevel);
            }
          }

          final lowStockList = await repo.listLowStock();

          // All seeded products are low-stock by construction.
          expect(
            lowStockList.length,
            greaterThanOrEqualTo(specs.length),
            reason: 'All seeded low-stock products should appear in the list.',
          );

          // Verify sort order: for every adjacent pair (a, b), ratio_a <= ratio_b.
          for (var i = 0; i < lowStockList.length - 1; i++) {
            final a = lowStockList[i];
            final b = lowStockList[i + 1];

            final ratioA = a.product.lowStockThreshold == 0
                ? 0.0
                : a.stockLevel / a.product.lowStockThreshold;
            final ratioB = b.product.lowStockThreshold == 0
                ? 0.0
                : b.stockLevel / b.product.lowStockThreshold;

            expect(
              ratioA,
              lessThanOrEqualTo(ratioB),
              reason:
                  'Sort order violated at index $i: '
                  'item[$i] ratio=$ratioA (stock=${a.stockLevel}, '
                  'threshold=${a.product.lowStockThreshold}) > '
                  'item[${i + 1}] ratio=$ratioB (stock=${b.stockLevel}, '
                  'threshold=${b.product.lowStockThreshold}). '
                  'List must be sorted ascending by stock_level/threshold.',
            );
          }
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Edge case: single low-stock product — trivially sorted (no adjacent pair).
    // -------------------------------------------------------------------------
    Glados2(any.intInRange(1, 51), any.intInRange(1, 51), _exploreConfig).test(
      'single low-stock product list is trivially sorted',
      (stockLevel, threshold) async {
        // Ensure low-stock condition: stock <= threshold.
        final stock = stockLevel <= threshold ? stockLevel : threshold;

        final db = _openTestDb();
        try {
          final repo = ProductRepositoryImpl(db);

          final product = await _seedProduct(
            repo,
            name: 'Single-$stock-$threshold',
            lowStockThreshold: threshold,
          );

          if (stock > 0) {
            await _addBatch(db, product.id, stock);
          }

          final lowStockList = await repo.listLowStock();

          // A list of 0 or 1 elements is always sorted — just verify no crash
          // and the product appears.
          expect(lowStockList.length, greaterThanOrEqualTo(1));
        } finally {
          await db.close();
        }
      },
    );
  });
}
