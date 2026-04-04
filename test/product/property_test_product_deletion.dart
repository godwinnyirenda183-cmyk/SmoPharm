// Feature: pharmacy-pos, Property 26: Product Deletion Referential Integrity
//
// Validates: Requirements 1.5
//
// Property 26: For any product that has at least one associated Batch or Sale
// record, a deletion attempt SHALL be rejected. For any product with no
// associated records, deletion SHALL succeed.

import 'package:drift/native.dart';
import 'package:glados/glados.dart';
// Hide Drift-generated Product to avoid conflict with domain entity.
import 'package:pharmacy_pos/database/database.dart' hide Product;
import 'package:pharmacy_pos/data/repositories/product_repository_impl.dart';
import 'package:pharmacy_pos/domain/entities/product.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

AppDatabase _openTestDb() => AppDatabase.forTesting(NativeDatabase.memory());

/// Creates a product with the given [name] and returns it.
Future<Product> _seedProduct(ProductRepositoryImpl repo, String name) =>
    repo.create(ProductInput(
      name: name,
      genericName: '${name}Generic',
      category: 'General',
      unitOfMeasure: 'Tablet',
      sellingPrice: 500,
      lowStockThreshold: 10,
    ));

/// Inserts a batch linked to [productId] into [db].
Future<void> _insertBatch(AppDatabase db, String productId, String batchId) =>
    db.into(db.batches).insert(BatchesCompanion.insert(
          id: batchId,
          productId: productId,
          batchNumber: 'LOT-$batchId',
          expiryDate: DateTime(2027, 12, 31),
          supplierName: 'Supplier',
          quantityReceived: 50,
          quantityRemaining: 50,
          costPricePerUnit: 200,
        ));

/// Inserts a user, batch, sale, and sale item linked to [productId] into [db].
/// The batch is removed afterwards so only the sale item remains as the
/// referencing record (to test the sale-item guard independently).
Future<void> _insertSaleItemOnly(
    AppDatabase db, String productId, String suffix) async {
  final userId = 'user-$suffix';
  final batchId = 'batch-$suffix';
  final saleId = 'sale-$suffix';
  final saleItemId = 'si-$suffix';

  await db.into(db.users).insert(UsersCompanion.insert(
        id: userId,
        username: 'cashier-$suffix',
        passwordHash: 'hash',
        role: 'cashier',
      ));

  await db.into(db.batches).insert(BatchesCompanion.insert(
        id: batchId,
        productId: productId,
        batchNumber: 'LOT-$batchId',
        expiryDate: DateTime(2027, 12, 31),
        supplierName: 'Supplier',
        quantityReceived: 50,
        quantityRemaining: 50,
        costPricePerUnit: 200,
      ));

  await db.into(db.sales).insert(SalesCompanion.insert(
        id: saleId,
        userId: userId,
        totalZmw: 500,
        paymentMethod: 'Cash',
      ));

  await db.into(db.saleItems).insert(SaleItemsCompanion.insert(
        id: saleItemId,
        saleId: saleId,
        productId: productId,
        batchId: batchId,
        quantity: 1,
        unitPrice: 500,
        lineTotal: 500,
      ));

  // Remove the batch so only the sale item is the referencing record.
  await (db.delete(db.batches)..where((b) => b.id.equals(batchId))).go();
}

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

/// Minimum 100 iterations as required by the testing strategy.
final _exploreConfig = ExploreConfig(numRuns: 100);

/// Generates non-empty alphanumeric product names of length 4–10.
final _genProductName = any.letterOrDigits.map((s) {
  final padded = s.padRight(4, 'x');
  return padded.length > 10 ? padded.substring(0, 10) : padded;
});

// ---------------------------------------------------------------------------
// Property tests
// ---------------------------------------------------------------------------

void main() {
  group('Property 26: Product Deletion Referential Integrity', () {
    // -------------------------------------------------------------------------
    // Sub-property A: Deletion succeeds when no associated records exist
    //
    // For any product with no associated Batch or SaleItem records, calling
    // delete() SHALL complete without error and the product SHALL be absent
    // from the database afterwards.
    // -------------------------------------------------------------------------
    Glados(_genProductName, _exploreConfig).test(
      'deletion succeeds for a product with no associated batches or sales',
      (name) async {
        final db = _openTestDb();
        try {
          final repo = ProductRepositoryImpl(db);
          final product = await _seedProduct(repo, name);

          // No batches or sale items — deletion must succeed.
          await repo.delete(product.id);

          final all = await repo.listAll();
          expect(
            all.any((p) => p.product.id == product.id),
            isFalse,
            reason:
                'Product "$name" should have been removed from the database '
                'after deletion, but it is still present.',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Sub-property B: Deletion is rejected when an associated Batch exists
    //
    // For any product that has at least one Batch record, calling delete()
    // SHALL throw a StateError and the product SHALL remain in the database.
    // -------------------------------------------------------------------------
    Glados(_genProductName, _exploreConfig).test(
      'deletion throws StateError when product has an associated batch',
      (name) async {
        final db = _openTestDb();
        try {
          final repo = ProductRepositoryImpl(db);
          final product = await _seedProduct(repo, name);

          await _insertBatch(db, product.id, 'b-${product.id.substring(0, 8)}');

          // Deletion must be rejected.
          await expectLater(
            () => repo.delete(product.id),
            throwsA(isA<StateError>()),
          );

          // Product must still exist.
          final all = await repo.listAll();
          expect(
            all.any((p) => p.product.id == product.id),
            isTrue,
            reason:
                'Product "$name" should still exist after a rejected deletion '
                '(batch present), but it was removed.',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Sub-property C: Deletion is rejected when an associated SaleItem exists
    //
    // For any product that has at least one SaleItem record (and no batch),
    // calling delete() SHALL throw a StateError and the product SHALL remain.
    // -------------------------------------------------------------------------
    Glados(_genProductName, _exploreConfig).test(
      'deletion throws StateError when product has an associated sale item',
      (name) async {
        final db = _openTestDb();
        try {
          final repo = ProductRepositoryImpl(db);
          final product = await _seedProduct(repo, name);

          await _insertSaleItemOnly(
              db, product.id, product.id.substring(0, 8));

          // Deletion must be rejected.
          await expectLater(
            () => repo.delete(product.id),
            throwsA(isA<StateError>()),
          );

          // Product must still exist.
          final all = await repo.listAll();
          expect(
            all.any((p) => p.product.id == product.id),
            isTrue,
            reason:
                'Product "$name" should still exist after a rejected deletion '
                '(sale item present), but it was removed.',
          );
        } finally {
          await db.close();
        }
      },
    );
  });
}
