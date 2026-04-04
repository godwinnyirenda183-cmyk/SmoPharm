// Feature: pharmacy-pos, Property 18: Offline Queue Capture
//
// Validates: Requirements 8.2
//
// Property 18: For any transaction (sale, stock-in, stock-adjustment) recorded
// while the device has no internet connectivity, the transaction SHALL be
// present in the Offline_Queue with the correct entity type, operation, and
// payload.
//
// This test verifies:
//   1. For any N sales created, the offline queue has exactly N entries with
//      entity_type='sale'.
//   2. For any N stock-ins created, the offline queue has exactly N entries
//      with entity_type='stock_in'.
//   3. For any N stock adjustments created, the offline queue has exactly N
//      entries with entity_type='stock_adjustment'.
//   4. Each entry has operation='INSERT' and synced=false.

import 'package:drift/drift.dart' hide Batch;
import 'package:drift/native.dart';
import 'package:glados/glados.dart';
import 'package:pharmacy_pos/data/repositories/sale_repository_impl.dart';
import 'package:pharmacy_pos/data/repositories/stock_adjustment_repository_impl.dart';
import 'package:pharmacy_pos/data/repositories/stock_in_repository_impl.dart';
import 'package:pharmacy_pos/data/services/offline_queue_service.dart';
import 'package:pharmacy_pos/database/database.dart' as db_lib;
import 'package:pharmacy_pos/domain/entities/batch.dart';
import 'package:pharmacy_pos/domain/entities/offline_queue_entry.dart';
import 'package:pharmacy_pos/domain/entities/sale.dart';
import 'package:pharmacy_pos/domain/entities/stock_adjustment.dart';
import 'package:pharmacy_pos/domain/repositories/stock_in_repository.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

db_lib.AppDatabase _openTestDb() =>
    db_lib.AppDatabase.forTesting(NativeDatabase.memory());

/// Inserts a minimal user row (required by FK) and returns the user id.
Future<String> _insertUser(db_lib.AppDatabase db, {String id = 'user-p18'}) async {
  await db.into(db.users).insert(db_lib.UsersCompanion.insert(
        id: id,
        username: 'user_$id',
        passwordHash: 'hash',
        role: 'admin',
      ));
  return id;
}

/// Inserts a product and returns its id.
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
        lowStockThreshold: 5,
      ));
  return id;
}

/// Inserts a non-expired batch for [productId] with [quantity] remaining.
Future<String> _insertBatch(
  db_lib.AppDatabase db, {
  required String productId,
  required String batchId,
  int quantity = 100,
}) async {
  await db.into(db.batches).insert(db_lib.BatchesCompanion.insert(
        id: batchId,
        productId: productId,
        batchNumber: 'LOT-$batchId',
        expiryDate: DateTime.now().add(const Duration(days: 365)),
        supplierName: 'Supplier',
        quantityReceived: quantity,
        quantityRemaining: quantity,
        costPricePerUnit: 200,
        status: const Value('active'),
      ));
  return batchId;
}

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

/// Minimum 100 iterations as required by the testing strategy.
final _exploreConfig = ExploreConfig(numRuns: 100);

/// Generates N in [1, 5].
final _genN = any.intInRange(1, 6);

// ---------------------------------------------------------------------------
// Property tests
// ---------------------------------------------------------------------------

void main() {
  group('Property 18: Offline Queue Capture', () {
    // -------------------------------------------------------------------------
    // Property 18a: For any N sales created, the offline queue has exactly N
    // entries with entity_type='sale', operation='INSERT', and synced=false.
    //
    // Strategy:
    //   1. Generate N in [1, 5].
    //   2. Seed N distinct products, each with a batch of sufficient stock.
    //   3. Create N sales (one item each, one per product) via SaleRepositoryImpl.
    //   4. Assert the offline queue has exactly N entries.
    //   5. Assert each entry has entity_type='sale', operation=INSERT, synced=false.
    // -------------------------------------------------------------------------
    Glados(_genN, _exploreConfig).test(
      'N sales produce exactly N offline queue entries with entity_type=sale',
      (n) async {
        final db = _openTestDb();
        try {
          final queueService = OfflineQueueService(db);
          final saleRepo = SaleRepositoryImpl(db, offlineQueue: queueService);
          final userId = await _insertUser(db);

          // Seed N products and batches.
          for (var i = 0; i < n; i++) {
            final productId = 'prod-sale-$i';
            await _insertProduct(db, id: productId, sellingPrice: 500);
            await _insertBatch(db, productId: productId, batchId: 'batch-sale-$i', quantity: 50);
          }

          // Create N sales, one item per product.
          for (var i = 0; i < n; i++) {
            await saleRepo.create(SaleInput(
              userId: userId,
              paymentMethod: PaymentMethod.cash,
              items: [SaleItemInput(productId: 'prod-sale-$i', quantity: 1)],
            ));
          }

          final entries = await queueService.listUnsynced();

          // Exactly N entries.
          expect(
            entries.length,
            equals(n),
            reason: 'Expected $n offline queue entries for $n sales, got ${entries.length}.',
          );

          // Each entry has the correct entity_type, operation, and synced=false.
          for (final entry in entries) {
            expect(
              entry.entityType,
              equals('sale'),
              reason: 'Expected entity_type=sale but got ${entry.entityType}.',
            );
            expect(
              entry.operation,
              equals(QueueOperation.insert),
              reason: 'Expected operation=INSERT but got ${entry.operation}.',
            );
            expect(
              entry.synced,
              isFalse,
              reason: 'Expected synced=false but got ${entry.synced}.',
            );
          }
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Property 18b: For any N stock-ins created, the offline queue has exactly
    // N entries with entity_type='stock_in', operation='INSERT', synced=false.
    //
    // Strategy:
    //   1. Generate N in [1, 5].
    //   2. Seed N distinct products.
    //   3. Create N stock-ins (one batch each) via StockInRepositoryImpl.
    //   4. Assert the offline queue has exactly N entries.
    //   5. Assert each entry has entity_type='stock_in', operation=INSERT, synced=false.
    // -------------------------------------------------------------------------
    Glados(_genN, _exploreConfig).test(
      'N stock-ins produce exactly N offline queue entries with entity_type=stock_in',
      (n) async {
        final db = _openTestDb();
        try {
          final queueService = OfflineQueueService(db);
          final stockInRepo = StockInRepositoryImpl(db, offlineQueue: queueService);
          final userId = await _insertUser(db);

          // Seed N products.
          for (var i = 0; i < n; i++) {
            await _insertProduct(db, id: 'prod-si-$i');
          }

          // Create N stock-ins, one per product.
          for (var i = 0; i < n; i++) {
            await stockInRepo.create(StockInCreateInput(
              userId: userId,
              batches: [
                StockInBatchInput(
                  batchInput: BatchInput(
                    productId: 'prod-si-$i',
                    batchNumber: 'LOT-SI-$i',
                    expiryDate: DateTime.now().add(const Duration(days: 365)),
                    supplierName: 'Supplier',
                    quantityReceived: 50,
                    costPricePerUnit: 200,
                  ),
                  quantity: 50,
                ),
              ],
            ));
          }

          final entries = await queueService.listUnsynced();

          // Exactly N entries.
          expect(
            entries.length,
            equals(n),
            reason: 'Expected $n offline queue entries for $n stock-ins, got ${entries.length}.',
          );

          // Each entry has the correct entity_type, operation, and synced=false.
          for (final entry in entries) {
            expect(
              entry.entityType,
              equals('stock_in'),
              reason: 'Expected entity_type=stock_in but got ${entry.entityType}.',
            );
            expect(
              entry.operation,
              equals(QueueOperation.insert),
              reason: 'Expected operation=INSERT but got ${entry.operation}.',
            );
            expect(
              entry.synced,
              isFalse,
              reason: 'Expected synced=false but got ${entry.synced}.',
            );
          }
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Property 18c: For any N stock adjustments created, the offline queue has
    // exactly N entries with entity_type='stock_adjustment', operation='INSERT',
    // synced=false.
    //
    // Strategy:
    //   1. Generate N in [1, 5].
    //   2. Seed N distinct products, each with a batch of sufficient stock.
    //   3. Create N stock adjustments (positive delta) via StockAdjustmentRepositoryImpl.
    //   4. Assert the offline queue has exactly N entries.
    //   5. Assert each entry has entity_type='stock_adjustment', operation=INSERT,
    //      synced=false.
    // -------------------------------------------------------------------------
    Glados(_genN, _exploreConfig).test(
      'N stock adjustments produce exactly N offline queue entries with entity_type=stock_adjustment',
      (n) async {
        final db = _openTestDb();
        try {
          final queueService = OfflineQueueService(db);
          final adjustmentRepo = StockAdjustmentRepositoryImpl(db, offlineQueue: queueService);
          final userId = await _insertUser(db);

          // Seed N products with batches.
          for (var i = 0; i < n; i++) {
            final productId = 'prod-adj-$i';
            await _insertProduct(db, id: productId);
            await _insertBatch(db, productId: productId, batchId: 'batch-adj-$i', quantity: 100);
          }

          // Create N stock adjustments (positive delta to avoid negative stock).
          for (var i = 0; i < n; i++) {
            await adjustmentRepo.create(StockAdjustmentInput(
              productId: 'prod-adj-$i',
              userId: userId,
              quantityDelta: 10,
              reasonCode: AdjustmentReasonCode.countCorrection,
            ));
          }

          final entries = await queueService.listUnsynced();

          // Exactly N entries.
          expect(
            entries.length,
            equals(n),
            reason: 'Expected $n offline queue entries for $n stock adjustments, got ${entries.length}.',
          );

          // Each entry has the correct entity_type, operation, and synced=false.
          for (final entry in entries) {
            expect(
              entry.entityType,
              equals('stock_adjustment'),
              reason: 'Expected entity_type=stock_adjustment but got ${entry.entityType}.',
            );
            expect(
              entry.operation,
              equals(QueueOperation.insert),
              reason: 'Expected operation=INSERT but got ${entry.operation}.',
            );
            expect(
              entry.synced,
              isFalse,
              reason: 'Expected synced=false but got ${entry.synced}.',
            );
          }
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Property 18d: Each offline queue entry payload contains the correct
    // entity id matching the created transaction.
    //
    // Strategy:
    //   1. Generate N in [1, 5].
    //   2. Create N sales, N stock-ins, and N stock adjustments.
    //   3. Assert each queue entry's entityId matches the corresponding
    //      transaction id returned by the repository.
    // -------------------------------------------------------------------------
    Glados(_genN, _exploreConfig).test(
      'each offline queue entry entityId matches the created transaction id',
      (n) async {
        final db = _openTestDb();
        try {
          final queueService = OfflineQueueService(db);
          final saleRepo = SaleRepositoryImpl(db, offlineQueue: queueService);
          final stockInRepo = StockInRepositoryImpl(db, offlineQueue: queueService);
          final adjustmentRepo = StockAdjustmentRepositoryImpl(db, offlineQueue: queueService);
          final userId = await _insertUser(db);

          // Seed products and batches for all transaction types.
          for (var i = 0; i < n; i++) {
            // For sales.
            await _insertProduct(db, id: 'prod-mix-sale-$i', sellingPrice: 500);
            await _insertBatch(db, productId: 'prod-mix-sale-$i', batchId: 'batch-mix-sale-$i', quantity: 50);
            // For adjustments.
            await _insertProduct(db, id: 'prod-mix-adj-$i');
            await _insertBatch(db, productId: 'prod-mix-adj-$i', batchId: 'batch-mix-adj-$i', quantity: 100);
            // For stock-ins (no pre-existing batch needed).
            await _insertProduct(db, id: 'prod-mix-si-$i');
          }

          // Collect created transaction ids.
          final saleIds = <String>[];
          final stockInIds = <String>[];
          final adjustmentIds = <String>[];

          for (var i = 0; i < n; i++) {
            final sale = await saleRepo.create(SaleInput(
              userId: userId,
              paymentMethod: PaymentMethod.cash,
              items: [SaleItemInput(productId: 'prod-mix-sale-$i', quantity: 1)],
            ));
            saleIds.add(sale.id);

            final stockIn = await stockInRepo.create(StockInCreateInput(
              userId: userId,
              batches: [
                StockInBatchInput(
                  batchInput: BatchInput(
                    productId: 'prod-mix-si-$i',
                    batchNumber: 'LOT-MIX-$i',
                    expiryDate: DateTime.now().add(const Duration(days: 365)),
                    supplierName: 'Supplier',
                    quantityReceived: 50,
                    costPricePerUnit: 200,
                  ),
                  quantity: 50,
                ),
              ],
            ));
            stockInIds.add(stockIn.id);

            final adjustment = await adjustmentRepo.create(StockAdjustmentInput(
              productId: 'prod-mix-adj-$i',
              userId: userId,
              quantityDelta: 5,
              reasonCode: AdjustmentReasonCode.other,
            ));
            adjustmentIds.add(adjustment.id);
          }

          final entries = await queueService.listUnsynced();

          // Total entries = 3 * N (N sales + N stock-ins + N adjustments).
          expect(
            entries.length,
            equals(3 * n),
            reason: 'Expected ${3 * n} total offline queue entries but got ${entries.length}.',
          );

          // Verify all sale ids are present in the queue.
          final queuedSaleIds = entries
              .where((e) => e.entityType == 'sale')
              .map((e) => e.entityId)
              .toSet();
          for (final id in saleIds) {
            expect(
              queuedSaleIds.contains(id),
              isTrue,
              reason: 'Sale id $id not found in offline queue.',
            );
          }

          // Verify all stock-in ids are present in the queue.
          final queuedStockInIds = entries
              .where((e) => e.entityType == 'stock_in')
              .map((e) => e.entityId)
              .toSet();
          for (final id in stockInIds) {
            expect(
              queuedStockInIds.contains(id),
              isTrue,
              reason: 'StockIn id $id not found in offline queue.',
            );
          }

          // Verify all adjustment ids are present in the queue.
          final queuedAdjIds = entries
              .where((e) => e.entityType == 'stock_adjustment')
              .map((e) => e.entityId)
              .toSet();
          for (final id in adjustmentIds) {
            expect(
              queuedAdjIds.contains(id),
              isTrue,
              reason: 'StockAdjustment id $id not found in offline queue.',
            );
          }

          // All entries must have operation=INSERT and synced=false.
          for (final entry in entries) {
            expect(
              entry.operation,
              equals(QueueOperation.insert),
              reason: 'Entry ${entry.id} has unexpected operation ${entry.operation}.',
            );
            expect(
              entry.synced,
              isFalse,
              reason: 'Entry ${entry.id} should not be synced.',
            );
          }
        } finally {
          await db.close();
        }
      },
    );
  });
}
