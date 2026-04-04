// Feature: pharmacy-pos, Property 3: Near-Expiry Flagging
//
// Validates: Requirements 2.4, 2.5, 7.4
//
// Property 3: For any batch whose expiry_date falls within
// [today, today + near_expiry_window_days], the batch status SHALL be
// near_expiry. For any batch whose expiry_date < today, the status SHALL be
// expired.

import 'package:drift/native.dart';
import 'package:glados/glados.dart';
import 'package:pharmacy_pos/data/repositories/batch_repository_impl.dart';
import 'package:pharmacy_pos/data/repositories/product_repository_impl.dart';
import 'package:pharmacy_pos/database/database.dart' hide Product;
import 'package:pharmacy_pos/domain/entities/batch.dart';
import 'package:pharmacy_pos/domain/entities/product.dart';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Fixed near-expiry window used throughout these tests.
const int _windowDays = 90;

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

/// Creates a batch with an expiry date offset by [dayOffset] days from today.
/// Negative offsets produce past dates; zero = today; positive = future.
Future<Batch> _createBatchWithOffset(
  BatchRepositoryImpl batchRepo,
  String productId,
  int dayOffset,
  String batchNumber,
) {
  final today = DateTime.now();
  final expiryDate = DateTime(today.year, today.month, today.day)
      .add(Duration(days: dayOffset));

  return batchRepo.create(
    BatchInput(
      productId: productId,
      batchNumber: batchNumber,
      expiryDate: expiryDate,
      supplierName: 'Supplier',
      quantityReceived: 10,
      costPricePerUnit: 100,
    ),
    nearExpiryWindowDays: _windowDays,
  );
}

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

/// Minimum 100 iterations as required by the testing strategy.
final _exploreConfig = ExploreConfig(numRuns: 100);

/// Generates a negative day offset in [-365, -1] → past dates → expired.
final _genPastOffset = any.intInRange(-365, 0);

/// Generates a day offset in [0, _windowDays] → near-expiry window.
final _genNearExpiryOffset = any.intInRange(0, _windowDays + 1);

/// Generates a day offset strictly beyond the window: [_windowDays + 1, 730].
final _genActiveOffset = any.intInRange(_windowDays + 1, 731);

// ---------------------------------------------------------------------------
// Property tests
// ---------------------------------------------------------------------------

void main() {
  group('Property 3: Near-Expiry Flagging', () {
    // -------------------------------------------------------------------------
    // Property 3a: Any batch with expiry_date < today → status == expired.
    //
    // Strategy:
    //   1. Generate a negative day offset (past date).
    //   2. Create a batch with that expiry date.
    //   3. Assert the returned batch status is BatchStatus.expired.
    // -------------------------------------------------------------------------
    Glados(_genPastOffset, _exploreConfig).test(
      'batch with expiry date in the past has status expired',
      (dayOffset) async {
        final db = _openTestDb();
        try {
          final productRepo = ProductRepositoryImpl(db);
          final batchRepo = BatchRepositoryImpl(db);

          final product = await _seedProduct(productRepo, 'past-$dayOffset');
          final batch = await _createBatchWithOffset(
            batchRepo,
            product.id,
            dayOffset,
            'PAST-LOT',
          );

          expect(
            batch.status,
            equals(BatchStatus.expired),
            reason:
                'Batch with expiry offset $dayOffset days (past) must be '
                'expired but got ${batch.status}.',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Property 3b: Any batch with expiry_date in [today, today + windowDays]
    //              → status == nearExpiry.
    //
    // Strategy:
    //   1. Generate a day offset in [0, _windowDays].
    //   2. Create a batch with that expiry date.
    //   3. Assert the returned batch status is BatchStatus.nearExpiry.
    // -------------------------------------------------------------------------
    Glados(_genNearExpiryOffset, _exploreConfig).test(
      'batch with expiry date within the near-expiry window has status near_expiry',
      (dayOffset) async {
        final db = _openTestDb();
        try {
          final productRepo = ProductRepositoryImpl(db);
          final batchRepo = BatchRepositoryImpl(db);

          final product =
              await _seedProduct(productRepo, 'near-$dayOffset');
          final batch = await _createBatchWithOffset(
            batchRepo,
            product.id,
            dayOffset,
            'NEAR-LOT',
          );

          expect(
            batch.status,
            equals(BatchStatus.nearExpiry),
            reason:
                'Batch with expiry offset $dayOffset days (within window of '
                '$_windowDays days) must be near_expiry but got ${batch.status}.',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Property 3c: Any batch with expiry_date > today + windowDays
    //              → status == active.
    //
    // Strategy:
    //   1. Generate a day offset strictly beyond the window.
    //   2. Create a batch with that expiry date.
    //   3. Assert the returned batch status is BatchStatus.active.
    // -------------------------------------------------------------------------
    Glados(_genActiveOffset, _exploreConfig).test(
      'batch with expiry date beyond the near-expiry window has status active',
      (dayOffset) async {
        final db = _openTestDb();
        try {
          final productRepo = ProductRepositoryImpl(db);
          final batchRepo = BatchRepositoryImpl(db);

          final product =
              await _seedProduct(productRepo, 'active-$dayOffset');
          final batch = await _createBatchWithOffset(
            batchRepo,
            product.id,
            dayOffset,
            'ACTIVE-LOT',
          );

          expect(
            batch.status,
            equals(BatchStatus.active),
            reason:
                'Batch with expiry offset $dayOffset days (beyond window of '
                '$_windowDays days) must be active but got ${batch.status}.',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Boundary: expiry exactly on today → near_expiry (inclusive lower bound).
    // -------------------------------------------------------------------------
    test('batch expiring exactly today has status near_expiry', () async {
      final db = _openTestDb();
      try {
        final productRepo = ProductRepositoryImpl(db);
        final batchRepo = BatchRepositoryImpl(db);

        final product = await _seedProduct(productRepo, 'today');
        final batch = await _createBatchWithOffset(
          batchRepo,
          product.id,
          0, // today
          'TODAY-LOT',
        );

        expect(
          batch.status,
          equals(BatchStatus.nearExpiry),
          reason: 'Batch expiring today must be near_expiry.',
        );
      } finally {
        await db.close();
      }
    });

    // -------------------------------------------------------------------------
    // Boundary: expiry exactly on today + windowDays → near_expiry (inclusive
    // upper bound).
    // -------------------------------------------------------------------------
    test(
        'batch expiring exactly on the last day of the window has status near_expiry',
        () async {
      final db = _openTestDb();
      try {
        final productRepo = ProductRepositoryImpl(db);
        final batchRepo = BatchRepositoryImpl(db);

        final product = await _seedProduct(productRepo, 'window-end');
        final batch = await _createBatchWithOffset(
          batchRepo,
          product.id,
          _windowDays, // today + windowDays
          'WINDOW-END-LOT',
        );

        expect(
          batch.status,
          equals(BatchStatus.nearExpiry),
          reason:
              'Batch expiring exactly on today + $_windowDays days must be '
              'near_expiry.',
        );
      } finally {
        await db.close();
      }
    });

    // -------------------------------------------------------------------------
    // Boundary: expiry exactly one day beyond the window → active.
    // -------------------------------------------------------------------------
    test('batch expiring one day beyond the window has status active',
        () async {
      final db = _openTestDb();
      try {
        final productRepo = ProductRepositoryImpl(db);
        final batchRepo = BatchRepositoryImpl(db);

        final product = await _seedProduct(productRepo, 'beyond-window');
        final batch = await _createBatchWithOffset(
          batchRepo,
          product.id,
          _windowDays + 1,
          'BEYOND-LOT',
        );

        expect(
          batch.status,
          equals(BatchStatus.active),
          reason:
              'Batch expiring one day beyond the window must be active.',
        );
      } finally {
        await db.close();
      }
    });
  });
}
