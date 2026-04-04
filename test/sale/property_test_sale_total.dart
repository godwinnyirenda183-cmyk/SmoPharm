// Feature: pharmacy-pos, Property 8: Sale Total Calculation
//
// Validates: Requirements 5.3
//
// Property 8: For any sale with a list of sale items, the computed sale total
// SHALL equal the sum of (quantity * unit_price) for each sale item.
// All values are integer cents.

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
Future<String> _insertUser(db_lib.AppDatabase db) async {
  const id = 'user-prop8';
  await db.into(db.users).insert(db_lib.UsersCompanion.insert(
        id: id,
        username: 'cashier_prop8',
        passwordHash: 'hash',
        role: 'cashier',
      ));
  return id;
}

/// Insert a product with the given [sellingPrice] (integer cents) and return
/// its ID.
Future<String> _insertProduct(
  db_lib.AppDatabase db, {
  required String id,
  required int sellingPrice,
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

/// Insert a batch for [productId] with [quantity] remaining (non-expired).
Future<void> _insertBatch(
  db_lib.AppDatabase db, {
  required String productId,
  required int quantity,
  required String batchId,
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
}

// ---------------------------------------------------------------------------
// Data class for a generated sale item spec
// ---------------------------------------------------------------------------

class _ItemSpec {
  final int quantity;   // 1–50
  final int unitPrice;  // 100–5000 cents

  const _ItemSpec(this.quantity, this.unitPrice);

  int get lineTotal => quantity * unitPrice;

  @override
  String toString() => '_ItemSpec(qty=$quantity, price=$unitPrice)';
}

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

/// Minimum 100 iterations as required by the testing strategy.
final _exploreConfig = ExploreConfig(numRuns: 100);

/// Generates a single item spec: quantity in [1, 50], unit price in [100, 5000].
final _genItemSpec = Glados2(
  any.intInRange(1, 51),    // quantity
  any.intInRange(100, 5001), // unit price in cents
).explore; // not used directly — we compose below

/// Generates a list of 1–5 item specs.
final _genItemSpecs = any
    .list(
      any.intInRange(1, 51).bind(
        (qty) => any.intInRange(100, 5001).map(
          (price) => _ItemSpec(qty, price),
        ),
      ),
    )
    .map((list) {
      if (list.isEmpty) return [const _ItemSpec(1, 100)];
      if (list.length > 5) return list.sublist(0, 5);
      return list;
    });

// ---------------------------------------------------------------------------
// Property tests
// ---------------------------------------------------------------------------

void main() {
  group('Property 8: Sale Total Calculation', () {
    // -------------------------------------------------------------------------
    // Core property: sale.totalZmw == sum(quantity * unit_price) for all items.
    //
    // Strategy:
    //   1. Generate a list of 1–5 item specs (quantity, unit_price).
    //   2. Seed one product per item with the generated unit price as
    //      selling_price and sufficient stock.
    //   3. Create a sale via SaleRepositoryImpl.create().
    //   4. Assert sale.totalZmw == sum of (quantity * unit_price).
    //   5. Assert each sale item's lineTotal == quantity * unit_price.
    // -------------------------------------------------------------------------
    Glados(_genItemSpecs, _exploreConfig).test(
      'sale total equals sum of (quantity * unit_price) for all items',
      (itemSpecs) async {
        final db = _openTestDb();
        try {
          final repo = SaleRepositoryImpl(db);
          final userId = await _insertUser(db);

          // Seed one product + batch per item spec.
          final saleInputItems = <SaleItemInput>[];
          final expectedLineTotals = <int>[];

          for (var i = 0; i < itemSpecs.length; i++) {
            final spec = itemSpecs[i];
            final productId = 'prod-p8-$i';
            final batchId = 'batch-p8-$i';

            await _insertProduct(db,
                id: productId, sellingPrice: spec.unitPrice);
            await _insertBatch(db,
                productId: productId,
                quantity: spec.quantity + 10, // ensure sufficient stock
                batchId: batchId);

            saleInputItems
                .add(SaleItemInput(productId: productId, quantity: spec.quantity));
            expectedLineTotals.add(spec.lineTotal);
          }

          final expectedTotal =
              expectedLineTotals.fold<int>(0, (sum, t) => sum + t);

          final sale = await repo.create(SaleInput(
            userId: userId,
            paymentMethod: PaymentMethod.cash,
            items: saleInputItems,
          ));

          // Verify overall sale total.
          expect(
            sale.totalZmw,
            equals(expectedTotal),
            reason:
                'sale.totalZmw should be $expectedTotal '
                '(sum of quantity*unit_price) but got ${sale.totalZmw}. '
                'itemSpecs=$itemSpecs',
          );

          // Verify each line total individually.
          for (var i = 0; i < itemSpecs.length; i++) {
            final spec = itemSpecs[i];
            final item = sale.items[i];
            expect(
              item.lineTotal,
              equals(spec.lineTotal),
              reason:
                  'Item $i lineTotal should be ${spec.lineTotal} '
                  '(${spec.quantity} * ${spec.unitPrice}) '
                  'but got ${item.lineTotal}.',
            );
          }
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Edge case: single item sale — total equals quantity * unit_price.
    // -------------------------------------------------------------------------
    Glados2(
      any.intInRange(1, 51),     // quantity
      any.intInRange(100, 5001), // unit price in cents
      _exploreConfig,
    ).test(
      'single-item sale total equals quantity * unit_price',
      (quantity, unitPrice) async {
        final db = _openTestDb();
        try {
          final repo = SaleRepositoryImpl(db);
          final userId = await _insertUser(db);

          await _insertProduct(db, id: 'prod-single', sellingPrice: unitPrice);
          await _insertBatch(db,
              productId: 'prod-single',
              quantity: quantity + 10,
              batchId: 'batch-single');

          final sale = await repo.create(SaleInput(
            userId: userId,
            paymentMethod: PaymentMethod.cash,
            items: [SaleItemInput(productId: 'prod-single', quantity: quantity)],
          ));

          final expected = quantity * unitPrice;

          expect(
            sale.totalZmw,
            equals(expected),
            reason:
                'Single-item sale total should be $expected '
                '($quantity * $unitPrice) but got ${sale.totalZmw}.',
          );

          expect(
            sale.items.first.lineTotal,
            equals(expected),
            reason:
                'Single-item lineTotal should be $expected but got '
                '${sale.items.first.lineTotal}.',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Persistence: the total stored in the database matches the returned total.
    // -------------------------------------------------------------------------
    Glados(_genItemSpecs, _exploreConfig).test(
      'persisted sale total in database matches computed total',
      (itemSpecs) async {
        final db = _openTestDb();
        try {
          final repo = SaleRepositoryImpl(db);
          final userId = await _insertUser(db);

          final saleInputItems = <SaleItemInput>[];
          var expectedTotal = 0;

          for (var i = 0; i < itemSpecs.length; i++) {
            final spec = itemSpecs[i];
            final productId = 'prod-db-$i';
            final batchId = 'batch-db-$i';

            await _insertProduct(db,
                id: productId, sellingPrice: spec.unitPrice);
            await _insertBatch(db,
                productId: productId,
                quantity: spec.quantity + 10,
                batchId: batchId);

            saleInputItems
                .add(SaleItemInput(productId: productId, quantity: spec.quantity));
            expectedTotal += spec.lineTotal;
          }

          final sale = await repo.create(SaleInput(
            userId: userId,
            paymentMethod: PaymentMethod.cash,
            items: saleInputItems,
          ));

          // Read back from DB and verify persisted total.
          final row = await (db.select(db.sales)
                ..where((s) => s.id.equals(sale.id)))
              .getSingle();

          expect(
            row.totalZmw,
            equals(expectedTotal),
            reason:
                'Persisted totalZmw should be $expectedTotal but got '
                '${row.totalZmw}. itemSpecs=$itemSpecs',
          );
        } finally {
          await db.close();
        }
      },
    );
  });
}
