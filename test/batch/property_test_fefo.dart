// Feature: pharmacy-pos, Property 2: FEFO Batch Selection
//
// Validates: Requirements 2.3, 5.4
//
// Property 2: For any product with multiple non-expired batches that have
// sufficient stock, the batch selected for dispensing SHALL be the one with
// the earliest expiry_date.

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

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

/// Minimum 100 iterations as required by the testing strategy.
final _exploreConfig = ExploreConfig(numRuns: 100);

/// Generates a list of 2–5 distinct positive offsets (days from today).
/// Each offset is in [1, 500] so all batches are non-expired.
final _genFutureDayOffsets = any
    .list(any.intInRange(1, 501))
    .map((list) {
      // Deduplicate and clamp to 2–5 elements.
      final unique = list.toSet().toList();
      if (unique.length < 2) {
        // Ensure at least 2 distinct offsets.
        return [1, 2];
      }
      if (unique.length > 5) return unique.sublist(0, 5);
      return unique;
    });

// ---------------------------------------------------------------------------
// Property tests
// ---------------------------------------------------------------------------

void main() {
  group('Property 2: FEFO Batch Selection', () {
    // -------------------------------------------------------------------------
    // Core property: selectFEFO returns the batch with the earliest expiry date
    // among all non-expired batches with sufficient stock.
    //
    // Strategy:
    //   1. Generate 2–5 distinct future day offsets.
    //   2. Create one batch per offset with quantity = 10 (sufficient stock).
    //   3. Call selectFEFO(productId, 1).
    //   4. Assert the returned batch has the minimum expiry date.
    // -------------------------------------------------------------------------
    Glados(_genFutureDayOffsets, _exploreConfig).test(
      'selectFEFO returns the batch with the earliest expiry date',
      (dayOffsets) async {
        final db = _openTestDb();
        try {
          final productRepo = ProductRepositoryImpl(db);
          final batchRepo = BatchRepositoryImpl(db);

          final product = await _seedProduct(productRepo, 'fefo');
          final today = DateTime.now();

          // Insert one batch per offset.
          for (var i = 0; i < dayOffsets.length; i++) {
            final expiry = today.add(Duration(days: dayOffsets[i]));
            await batchRepo.create(
              BatchInput(
                productId: product.id,
                batchNumber: 'LOT-$i',
                expiryDate: expiry,
                supplierName: 'Supplier',
                quantityReceived: 10,
                costPricePerUnit: 100,
              ),
              nearExpiryWindowDays: 90,
            );
          }

          // The expected earliest expiry is today + min(dayOffsets) days.
          final minOffset = dayOffsets.reduce((a, b) => a < b ? a : b);
          final expectedExpiry = DateTime(
            today.year,
            today.month,
            today.day,
          ).add(Duration(days: minOffset));

          final selected = await batchRepo.selectFEFO(product.id, 1);

          expect(
            selected,
            isNotNull,
            reason: 'selectFEFO must return a batch when non-expired batches '
                'with sufficient stock exist.',
          );

          final selectedExpiry = DateTime(
            selected!.expiryDate.year,
            selected.expiryDate.month,
            selected.expiryDate.day,
          );

          expect(
            selectedExpiry,
            equals(expectedExpiry),
            reason:
                'Expected batch with expiry $expectedExpiry (earliest) but got '
                '${selected.expiryDate}. dayOffsets=$dayOffsets',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Expired batches are never selected even if they have the earliest expiry.
    //
    // Strategy:
    //   1. Insert one expired batch (yesterday) with quantity = 10.
    //   2. Insert one non-expired batch (tomorrow) with quantity = 10.
    //   3. Call selectFEFO(productId, 1).
    //   4. Assert the returned batch is the non-expired one.
    // -------------------------------------------------------------------------
    Glados(any.positiveInt, _exploreConfig).test(
      'expired batches are never selected even if they have the earliest expiry',
      (_) async {
        final db = _openTestDb();
        try {
          final productRepo = ProductRepositoryImpl(db);
          final batchRepo = BatchRepositoryImpl(db);

          final product = await _seedProduct(productRepo, 'noexp');
          final today = DateTime.now();

          // Expired batch — earliest date but must not be selected.
          await batchRepo.create(
            BatchInput(
              productId: product.id,
              batchNumber: 'EXPIRED-LOT',
              expiryDate: today.subtract(const Duration(days: 1)),
              supplierName: 'Supplier',
              quantityReceived: 10,
              costPricePerUnit: 100,
            ),
            nearExpiryWindowDays: 90,
          );

          // Non-expired batch — later date, should be selected.
          final futureExpiry = today.add(const Duration(days: 30));
          await batchRepo.create(
            BatchInput(
              productId: product.id,
              batchNumber: 'ACTIVE-LOT',
              expiryDate: futureExpiry,
              supplierName: 'Supplier',
              quantityReceived: 10,
              costPricePerUnit: 100,
            ),
            nearExpiryWindowDays: 90,
          );

          final selected = await batchRepo.selectFEFO(product.id, 1);

          expect(
            selected,
            isNotNull,
            reason: 'selectFEFO must return the non-expired batch.',
          );

          expect(
            selected!.batchNumber,
            equals('ACTIVE-LOT'),
            reason: 'The expired batch must never be selected; expected '
                'ACTIVE-LOT but got ${selected.batchNumber}.',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // selectFEFO returns null when all batches are expired.
    //
    // Strategy:
    //   1. Generate 1–4 positive quantities.
    //   2. Insert one expired batch per quantity.
    //   3. Call selectFEFO(productId, 1).
    //   4. Assert null is returned.
    // -------------------------------------------------------------------------
    Glados(
      any.list(any.intInRange(1, 201)).map((list) {
        if (list.isEmpty) return [10];
        if (list.length > 4) return list.sublist(0, 4);
        return list;
      }),
      _exploreConfig,
    ).test(
      'selectFEFO returns null when all batches are expired',
      (quantities) async {
        final db = _openTestDb();
        try {
          final productRepo = ProductRepositoryImpl(db);
          final batchRepo = BatchRepositoryImpl(db);

          final product = await _seedProduct(productRepo, 'allexp');
          final today = DateTime.now();

          for (var i = 0; i < quantities.length; i++) {
            await batchRepo.create(
              BatchInput(
                productId: product.id,
                batchNumber: 'EXP-$i',
                expiryDate: today.subtract(Duration(days: i + 1)),
                supplierName: 'Supplier',
                quantityReceived: quantities[i],
                costPricePerUnit: 100,
              ),
              nearExpiryWindowDays: 90,
            );
          }

          final selected = await batchRepo.selectFEFO(product.id, 1);

          expect(
            selected,
            isNull,
            reason: 'selectFEFO must return null when all batches are expired.',
          );
        } finally {
          await db.close();
        }
      },
    );
  });
}
