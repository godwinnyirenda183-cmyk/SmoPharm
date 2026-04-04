// Feature: pharmacy-pos, Property 16: Inventory Report Stock Value
//
// Validates: Requirements 7.2
//
// Property 16: For any product, the total stock value reported in the Current
// Inventory Report SHALL equal the sum of
// (batch.quantity_remaining * batch.cost_price_per_unit) across all
// non-expired batches for that product.

import 'package:drift/drift.dart' hide Batch;
import 'package:drift/native.dart';
import 'package:glados/glados.dart';
import 'package:pharmacy_pos/data/repositories/product_repository_impl.dart';
import 'package:pharmacy_pos/data/services/report_service_impl.dart';
import 'package:pharmacy_pos/database/database.dart' as db_lib;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

db_lib.AppDatabase _openTestDb() =>
    db_lib.AppDatabase.forTesting(NativeDatabase.memory());

/// Insert a minimal product row and return its id.
Future<String> _insertProduct(db_lib.AppDatabase db, String suffix) async {
  final id = 'prod-p16-$suffix';
  await db.into(db.products).insert(db_lib.ProductsCompanion.insert(
        id: id,
        name: 'Product $suffix',
        genericName: 'Generic $suffix',
        category: 'Medicine',
        unitOfMeasure: 'Tablet',
        sellingPrice: 500,
        lowStockThreshold: 10,
      ));
  return id;
}

/// Insert a batch row with explicit status, quantity, and cost.
Future<void> _insertBatch(
  db_lib.AppDatabase db, {
  required String id,
  required String productId,
  required int quantityRemaining,
  required int costPricePerUnit,
  required String status, // 'active' | 'near_expiry' | 'expired'
}) async {
  final expiryDate = status == 'expired'
      ? DateTime(2020, 1, 1) // past date → expired
      : DateTime(2099, 12, 31); // far future → active/near_expiry

  await db.into(db.batches).insert(db_lib.BatchesCompanion.insert(
        id: id,
        productId: productId,
        batchNumber: 'BN-$id',
        expiryDate: expiryDate,
        supplierName: 'Supplier',
        quantityReceived: quantityRemaining,
        quantityRemaining: quantityRemaining,
        costPricePerUnit: costPricePerUnit,
        status: Value(status),
      ));
}

// ---------------------------------------------------------------------------
// Data class for a generated batch spec
// ---------------------------------------------------------------------------

class _BatchSpec {
  final int quantity; // [1, 100]
  final int costPrice; // [100, 1000] cents
  final bool expired;

  const _BatchSpec(this.quantity, this.costPrice, this.expired);

  @override
  String toString() =>
      '_BatchSpec(qty=$quantity, cost=$costPrice, expired=$expired)';
}

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

/// Minimum 100 iterations as required by the testing strategy.
final _exploreConfig = ExploreConfig(numRuns: 100);

/// Generates a single batch spec.
final _genBatchSpec = any.intInRange(1, 101).bind(
      (qty) => any.intInRange(100, 1001).bind(
            (cost) => any.bool.map((exp) => _BatchSpec(qty, cost, exp)),
          ),
    );

/// Generates a list of 1–5 batch specs (mix of expired and non-expired).
final _genBatchSpecs = any.list(_genBatchSpec).map((list) {
  if (list.isEmpty) return [const _BatchSpec(10, 200, false)];
  if (list.length > 5) return list.sublist(0, 5);
  return list;
});

/// Generates a list of 1–5 non-expired batch specs only.
final _genNonExpiredBatchSpecs = any.list(_genBatchSpec).map((list) {
  final nonExpired = list.where((s) => !s.expired).toList();
  if (nonExpired.isEmpty) return [const _BatchSpec(10, 200, false)];
  if (nonExpired.length > 5) return nonExpired.sublist(0, 5);
  return nonExpired;
});

// ---------------------------------------------------------------------------
// Property tests
// ---------------------------------------------------------------------------

void main() {
  group('Property 16: Inventory Report Stock Value', () {
    // -------------------------------------------------------------------------
    // Property A: total stock value equals sum(qty * cost) for non-expired
    //             batches, across a mix of expired and non-expired batches.
    //
    // Strategy:
    //   1. Generate 1–5 batch specs (random qty, cost, expired flag).
    //   2. Insert a product and all batches into an in-memory DB.
    //   3. Call inventoryReport().
    //   4. Assert the row's totalValueCents == sum(qty * cost) for
    //      non-expired batches only.
    // -------------------------------------------------------------------------
    Glados(_genBatchSpecs, _exploreConfig).test(
      'totalValueCents equals sum(qty * cost) for non-expired batches',
      (specs) async {
        final db = _openTestDb();
        try {
          final productRepo = ProductRepositoryImpl(db);
          final service = ReportServiceImpl(db, productRepo);

          final productId = await _insertProduct(db, 'a-${specs.hashCode}');

          int expectedValue = 0;

          for (var i = 0; i < specs.length; i++) {
            final spec = specs[i];
            final status = spec.expired ? 'expired' : 'active';
            await _insertBatch(
              db,
              id: 'batch-p16a-${specs.hashCode}-$i',
              productId: productId,
              quantityRemaining: spec.quantity,
              costPricePerUnit: spec.costPrice,
              status: status,
            );
            if (!spec.expired) {
              expectedValue += spec.quantity * spec.costPrice;
            }
          }

          final report = await service.inventoryReport();
          final row = report.firstWhere((r) => r.product.id == productId);

          expect(
            row.totalValueCents,
            equals(expectedValue),
            reason:
                'totalValueCents should be $expectedValue '
                '(sum of qty*cost for non-expired batches) but got '
                '${row.totalValueCents}. specs=$specs',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Property B: expired batches are excluded from total stock value.
    //
    // Strategy:
    //   1. Generate 1–5 non-expired batch specs.
    //   2. Insert those plus 1–3 expired batches with known values.
    //   3. Assert totalValueCents does NOT include the expired batch values.
    // -------------------------------------------------------------------------
    Glados(_genNonExpiredBatchSpecs, _exploreConfig).test(
      'expired batches are excluded from total stock value',
      (nonExpiredSpecs) async {
        final db = _openTestDb();
        try {
          final productRepo = ProductRepositoryImpl(db);
          final service = ReportServiceImpl(db, productRepo);

          final productId =
              await _insertProduct(db, 'b-${nonExpiredSpecs.hashCode}');

          int expectedValue = 0;
          int idx = 0;

          // Insert non-expired batches.
          for (final spec in nonExpiredSpecs) {
            await _insertBatch(
              db,
              id: 'batch-p16b-ne-${nonExpiredSpecs.hashCode}-$idx',
              productId: productId,
              quantityRemaining: spec.quantity,
              costPricePerUnit: spec.costPrice,
              status: 'active',
            );
            expectedValue += spec.quantity * spec.costPrice;
            idx++;
          }

          // Insert a fixed expired batch — must NOT contribute to value.
          await _insertBatch(
            db,
            id: 'batch-p16b-exp-${nonExpiredSpecs.hashCode}',
            productId: productId,
            quantityRemaining: 50,
            costPricePerUnit: 999,
            status: 'expired',
          );

          final report = await service.inventoryReport();
          final row = report.firstWhere((r) => r.product.id == productId);

          expect(
            row.totalValueCents,
            equals(expectedValue),
            reason:
                'totalValueCents should be $expectedValue '
                '(expired batch excluded) but got '
                '${row.totalValueCents}. nonExpiredSpecs=$nonExpiredSpecs',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Property C: near_expiry batches ARE included in total stock value.
    //
    // Strategy:
    //   1. Generate 1–5 batch specs (all non-expired, some near_expiry).
    //   2. Insert batches with status 'near_expiry' for odd indices,
    //      'active' for even indices.
    //   3. Assert totalValueCents includes ALL non-expired batches
    //      (both active and near_expiry).
    // -------------------------------------------------------------------------
    Glados(_genNonExpiredBatchSpecs, _exploreConfig).test(
      'near_expiry batches are included in total stock value',
      (specs) async {
        final db = _openTestDb();
        try {
          final productRepo = ProductRepositoryImpl(db);
          final service = ReportServiceImpl(db, productRepo);

          final productId = await _insertProduct(db, 'c-${specs.hashCode}');

          int expectedValue = 0;

          for (var i = 0; i < specs.length; i++) {
            final spec = specs[i];
            // Alternate between active and near_expiry.
            final status = i.isEven ? 'active' : 'near_expiry';
            await _insertBatch(
              db,
              id: 'batch-p16c-${specs.hashCode}-$i',
              productId: productId,
              quantityRemaining: spec.quantity,
              costPricePerUnit: spec.costPrice,
              status: status,
            );
            // Both active and near_expiry contribute to value.
            expectedValue += spec.quantity * spec.costPrice;
          }

          final report = await service.inventoryReport();
          final row = report.firstWhere((r) => r.product.id == productId);

          expect(
            row.totalValueCents,
            equals(expectedValue),
            reason:
                'totalValueCents should be $expectedValue '
                '(near_expiry batches included) but got '
                '${row.totalValueCents}. specs=$specs',
          );
        } finally {
          await db.close();
        }
      },
    );
  });
}
