import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_pos/data/repositories/sale_repository_impl.dart';
import 'package:pharmacy_pos/data/repositories/stock_adjustment_repository_impl.dart';
import 'package:pharmacy_pos/data/repositories/stock_in_repository_impl.dart';
import 'package:pharmacy_pos/data/services/offline_queue_service.dart';
import 'package:pharmacy_pos/database/database.dart' as db_lib;
import 'package:pharmacy_pos/domain/entities/offline_queue_entry.dart';
import 'package:pharmacy_pos/domain/entities/batch.dart';
import 'package:pharmacy_pos/domain/entities/sale.dart';
import 'package:pharmacy_pos/domain/entities/stock_adjustment.dart';
import 'package:pharmacy_pos/domain/repositories/stock_in_repository.dart';

db_lib.AppDatabase _openTestDb() =>
    db_lib.AppDatabase.forTesting(NativeDatabase.memory());

Future<String> _insertUser(db_lib.AppDatabase db,
    {String id = 'user-1'}) async {
  await db.into(db.users).insert(db_lib.UsersCompanion.insert(
        id: id,
        username: 'user_$id',
        passwordHash: 'hash',
        role: 'admin',
      ));
  return id;
}

Future<String> _insertProduct(db_lib.AppDatabase db,
    {String id = 'prod-1', String name = 'Paracetamol'}) async {
  await db.into(db.products).insert(db_lib.ProductsCompanion.insert(
        id: id,
        name: name,
        genericName: 'Generic',
        category: 'Analgesic',
        unitOfMeasure: 'Tablet',
        sellingPrice: 500,
        lowStockThreshold: 10,
      ));
  return id;
}

Future<String> _insertBatch(db_lib.AppDatabase db,
    {required String productId, int quantity = 50}) async {
  final batchId = 'batch-${DateTime.now().microsecondsSinceEpoch}';
  await db.into(db.batches).insert(db_lib.BatchesCompanion.insert(
        id: batchId,
        productId: productId,
        batchNumber: 'LOT001',
        expiryDate: DateTime.now().add(const Duration(days: 365)),
        supplierName: 'Supplier A',
        quantityReceived: quantity,
        quantityRemaining: quantity,
        costPricePerUnit: 200,
      ));
  return batchId;
}

void main() {
  group('OfflineQueue write path', () {
    late db_lib.AppDatabase db;
    late OfflineQueueService queueService;

    setUp(() {
      db = _openTestDb();
      queueService = OfflineQueueService(db);
    });

    tearDown(() async {
      await db.close();
    });

    // -------------------------------------------------------------------------
    // Sale creates an offline queue entry
    // -------------------------------------------------------------------------

    test('sale create inserts an offline queue entry', () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);
      await _insertBatch(db, productId: productId, quantity: 50);

      final repo = SaleRepositoryImpl(db, offlineQueue: queueService);
      final sale = await repo.create(SaleInput(
        userId: userId,
        paymentMethod: PaymentMethod.cash,
        items: [SaleItemInput(productId: productId, quantity: 5)],
      ));

      final unsynced = await queueService.listUnsynced();
      expect(unsynced, hasLength(1));

      final entry = unsynced.first;
      expect(entry.entityType, equals('sale'));
      expect(entry.entityId, equals(sale.id));
      expect(entry.operation, equals(QueueOperation.insert));
      expect(entry.synced, isFalse);

      final payload = jsonDecode(entry.payloadJson) as Map<String, dynamic>;
      expect(payload['id'], equals(sale.id));
      expect(payload['userId'], equals(userId));
    });

    // -------------------------------------------------------------------------
    // Stock-in creates an offline queue entry
    // -------------------------------------------------------------------------

    test('stock-in create inserts an offline queue entry', () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);

      final repo = StockInRepositoryImpl(db, offlineQueue: queueService);
      final stockIn = await repo.create(StockInCreateInput(
        userId: userId,
        batches: [
          StockInBatchInput(
            batchInput: BatchInput(
              productId: productId,
              batchNumber: 'LOT-SI-001',
              expiryDate: DateTime.now().add(const Duration(days: 365)),
              supplierName: 'Supplier B',
              quantityReceived: 100,
              costPricePerUnit: 150,
            ),
            quantity: 100,
          ),
        ],
      ));

      final unsynced = await queueService.listUnsynced();
      expect(unsynced, hasLength(1));

      final entry = unsynced.first;
      expect(entry.entityType, equals('stock_in'));
      expect(entry.entityId, equals(stockIn.id));
      expect(entry.operation, equals(QueueOperation.insert));
      expect(entry.synced, isFalse);

      final payload = jsonDecode(entry.payloadJson) as Map<String, dynamic>;
      expect(payload['id'], equals(stockIn.id));
      expect(payload['userId'], equals(userId));
    });

    // -------------------------------------------------------------------------
    // Stock adjustment creates an offline queue entry
    // -------------------------------------------------------------------------

    test('stock adjustment create inserts an offline queue entry', () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);
      await _insertBatch(db, productId: productId, quantity: 50);

      final repo =
          StockAdjustmentRepositoryImpl(db, offlineQueue: queueService);
      final adjustment = await repo.create(StockAdjustmentInput(
        productId: productId,
        userId: userId,
        quantityDelta: -5,
        reasonCode: AdjustmentReasonCode.damaged,
      ));

      final unsynced = await queueService.listUnsynced();
      expect(unsynced, hasLength(1));

      final entry = unsynced.first;
      expect(entry.entityType, equals('stock_adjustment'));
      expect(entry.entityId, equals(adjustment.id));
      expect(entry.operation, equals(QueueOperation.insert));
      expect(entry.synced, isFalse);

      final payload = jsonDecode(entry.payloadJson) as Map<String, dynamic>;
      expect(payload['id'], equals(adjustment.id));
      expect(payload['quantityDelta'], equals(-5));
    });

    // -------------------------------------------------------------------------
    // listUnsynced returns only unsynced entries
    // -------------------------------------------------------------------------

    test('listUnsynced returns only entries where synced=false', () async {
      // Enqueue two entries.
      await queueService.enqueue(
        entityType: 'sale',
        entityId: 'sale-1',
        operation: 'INSERT',
        payloadJson: '{}',
      );
      final entry2 = await queueService.enqueue(
        entityType: 'sale',
        entityId: 'sale-2',
        operation: 'INSERT',
        payloadJson: '{}',
      );

      // Mark the second one as synced.
      await queueService.markSynced(entry2.id);

      final unsynced = await queueService.listUnsynced();
      expect(unsynced, hasLength(1));
      expect(unsynced.first.entityId, equals('sale-1'));
    });

    // -------------------------------------------------------------------------
    // markSynced marks an entry as synced
    // -------------------------------------------------------------------------

    test('markSynced sets synced=true for the given entry', () async {
      final entry = await queueService.enqueue(
        entityType: 'stock_in',
        entityId: 'si-1',
        operation: 'INSERT',
        payloadJson: '{"id":"si-1"}',
      );

      // Before marking: should be in unsynced list.
      final before = await queueService.listUnsynced();
      expect(before.any((e) => e.id == entry.id), isTrue);

      await queueService.markSynced(entry.id);

      // After marking: should NOT be in unsynced list.
      final after = await queueService.listUnsynced();
      expect(after.any((e) => e.id == entry.id), isFalse);

      // Verify the row in the DB is actually synced.
      final row = await (db.select(db.offlineQueue)
            ..where((q) => q.id.equals(entry.id)))
          .getSingle();
      expect(row.synced, isTrue);
    });
  });
}
