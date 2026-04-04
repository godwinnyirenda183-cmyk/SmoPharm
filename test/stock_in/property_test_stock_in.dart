// Feature: pharmacy-pos, Property 5: Stock-In Increases Stock Level
//
// Validates: Requirements 3.1, 3.4
//
// Property 5: For any product with a current Stock_Level S and any Stock_In of
// positive quantity Q, the resulting Stock_Level SHALL equal S + Q.
// For any quantity ≤ 0, the stock-in is rejected and stock level remains S.

import 'package:drift/drift.dart' hide StockIn, StockInLine;
import 'package:drift/native.dart';
import 'package:glados/glados.dart';
import 'package:pharmacy_pos/data/repositories/product_repository_impl.dart';
import 'package:pharmacy_pos/data/repositories/stock_in_repository_impl.dart';
import 'package:pharmacy_pos/database/database.dart' hide StockIn, StockInLine, Product;
import 'package:pharmacy_pos/domain/entities/batch.dart';
import 'package:pharmacy_pos/domain/entities/product.dart';
import 'package:pharmacy_pos/domain/repositories/stock_in_repository.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

AppDatabase _openTestDb() => AppDatabase.forTesting(NativeDatabase.memory());

/// Seeds a minimal user row (required by StockIn FK) and returns the user id.
Future<String> _insertUser(AppDatabase db, {String id = 'user-1'}) async {
  await db.into(db.users).insert(UsersCompanion.insert(
        id: id,
        username: 'pharmacist_$id',
        passwordHash: 'hash',
        role: 'admin',
      ));
  return id;
}

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

/// Inserts a pre-existing non-expired batch directly into the DB to establish
/// an initial stock level S for a product.
Future<void> _insertInitialBatch(
  AppDatabase db,
  String productId,
  int quantity,
  String batchNumber,
) async {
  await db.into(db.batches).insert(BatchesCompanion.insert(
        id: 'init-$batchNumber',
        productId: productId,
        batchNumber: batchNumber,
        expiryDate: DateTime.now().add(const Duration(days: 365)),
        supplierName: 'Initial Supplier',
        quantityReceived: quantity,
        quantityRemaining: quantity,
        costPricePerUnit: 100,
        status: const Value('active'),
      ));
}

/// Computes the current stock level for a product as the sum of
/// quantity_remaining across all non-expired batches.
Future<int> _stockLevel(AppDatabase db, String productId) async {
  final batches = await (db.select(db.batches)
        ..where((b) =>
            b.productId.equals(productId) &
            b.status.isNotIn(const ['expired'])))
      .get();
  return batches.fold<int>(0, (sum, b) => sum + b.quantityRemaining);
}

/// Builds a [StockInBatchInput] for a new batch on the given product.
StockInBatchInput _buildBatchInput({
  required String productId,
  required int quantity,
  String batchNumber = 'NEW-LOT',
}) =>
    StockInBatchInput(
      batchInput: BatchInput(
        productId: productId,
        batchNumber: batchNumber,
        expiryDate: DateTime.now().add(const Duration(days: 365)),
        supplierName: 'Supplier',
        quantityReceived: quantity,
        costPricePerUnit: 200,
      ),
      quantity: quantity,
    );

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

/// Minimum 100 iterations as required by the testing strategy.
final _exploreConfig = ExploreConfig(numRuns: 100);

/// Generates an initial stock level S in [0, 500].
final _genInitialStock = any.intInRange(0, 501);

/// Generates a positive stock-in quantity Q in [1, 500].
final _genPositiveQuantity = any.intInRange(1, 501);

/// Generates a non-positive quantity (≤ 0) in [-500, 0].
final _genNonPositiveQuantity = any.intInRange(-500, 1);

// ---------------------------------------------------------------------------
// Property tests
// ---------------------------------------------------------------------------

void main() {
  group('Property 5: Stock-In Increases Stock Level', () {
    // -------------------------------------------------------------------------
    // Core property: for any initial stock level S and positive quantity Q,
    // after a stock-in of Q the stock level equals S + Q.
    //
    // Strategy:
    //   1. Generate initial stock level S (0 or positive).
    //   2. Generate positive stock-in quantity Q.
    //   3. Seed a product and insert an initial batch of quantity S (skip if S=0).
    //   4. Record a stock-in of quantity Q.
    //   5. Assert stock level == S + Q.
    // -------------------------------------------------------------------------
    Glados2(_genInitialStock, _genPositiveQuantity, _exploreConfig).test(
      'stock level equals S + Q after a stock-in of positive quantity Q',
      (initialStock, quantity) async {
        final db = _openTestDb();
        try {
          final productRepo = ProductRepositoryImpl(db);
          final stockInRepo = StockInRepositoryImpl(db);
          final userId = await _insertUser(db);
          final product = await _seedProduct(productRepo, 'main');

          // Establish initial stock level S.
          if (initialStock > 0) {
            await _insertInitialBatch(db, product.id, initialStock, 'INIT');
          }

          final stockBefore = await _stockLevel(db, product.id);
          expect(
            stockBefore,
            equals(initialStock),
            reason: 'Pre-condition: initial stock level must equal $initialStock.',
          );

          // Perform the stock-in of quantity Q.
          await stockInRepo.create(StockInCreateInput(
            userId: userId,
            batches: [
              _buildBatchInput(
                productId: product.id,
                quantity: quantity,
                batchNumber: 'NEW-LOT',
              ),
            ],
          ));

          final stockAfter = await _stockLevel(db, product.id);

          expect(
            stockAfter,
            equals(initialStock + quantity),
            reason:
                'Expected stock level ${initialStock + quantity} (S=$initialStock + Q=$quantity) '
                'but got $stockAfter.',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Rejection property: for any quantity ≤ 0, the stock-in is rejected and
    // the stock level remains S.
    //
    // Strategy:
    //   1. Generate initial stock level S (0 or positive).
    //   2. Generate a non-positive quantity (≤ 0).
    //   3. Seed a product and insert an initial batch of quantity S (skip if S=0).
    //   4. Attempt a stock-in of the non-positive quantity.
    //   5. Assert an ArgumentError is thrown.
    //   6. Assert stock level is still S.
    // -------------------------------------------------------------------------
    Glados2(_genInitialStock, _genNonPositiveQuantity, _exploreConfig).test(
      'stock-in with quantity ≤ 0 is rejected and stock level remains S',
      (initialStock, invalidQuantity) async {
        final db = _openTestDb();
        try {
          final productRepo = ProductRepositoryImpl(db);
          final stockInRepo = StockInRepositoryImpl(db);
          final userId = await _insertUser(db);
          final product = await _seedProduct(productRepo, 'reject');

          // Establish initial stock level S.
          if (initialStock > 0) {
            await _insertInitialBatch(db, product.id, initialStock, 'INIT');
          }

          final stockBefore = await _stockLevel(db, product.id);

          // Attempt the invalid stock-in — must throw ArgumentError.
          Object? caughtError;
          try {
            await stockInRepo.create(StockInCreateInput(
              userId: userId,
              batches: [
                _buildBatchInput(
                  productId: product.id,
                  quantity: invalidQuantity,
                  batchNumber: 'BAD-LOT',
                ),
              ],
            ));
          } catch (e) {
            caughtError = e;
          }

          expect(
            caughtError,
            isA<ArgumentError>(),
            reason:
                'Expected ArgumentError for quantity=$invalidQuantity but no error was thrown.',
          );

          // Stock level must be unchanged.
          final stockAfter = await _stockLevel(db, product.id);
          expect(
            stockAfter,
            equals(stockBefore),
            reason:
                'Stock level must remain $stockBefore after a rejected stock-in '
                '(quantity=$invalidQuantity), but got $stockAfter.',
          );
        } finally {
          await db.close();
        }
      },
    );
  });
}
