import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_pos/data/repositories/sale_repository_impl.dart';
import 'package:pharmacy_pos/database/database.dart' as db_lib;
import 'package:pharmacy_pos/domain/entities/sale.dart';
import 'package:drift/drift.dart' hide Batch;

db_lib.AppDatabase _openTestDb() =>
    db_lib.AppDatabase.forTesting(NativeDatabase.memory());

Future<String> _insertUser(db_lib.AppDatabase db,
    {String id = 'user-1'}) async {
  await db.into(db.users).insert(db_lib.UsersCompanion.insert(
        id: id,
        username: 'cashier_$id',
        passwordHash: 'hash',
        role: 'cashier',
      ));
  return id;
}

Future<String> _insertProduct(
  db_lib.AppDatabase db, {
  String id = 'prod-1',
  String name = 'Paracetamol',
  int sellingPrice = 500,
}) async {
  await db.into(db.products).insert(db_lib.ProductsCompanion.insert(
        id: id,
        name: name,
        genericName: 'Generic $id',
        category: 'Analgesic',
        unitOfMeasure: 'Tablet',
        sellingPrice: sellingPrice,
        lowStockThreshold: 10,
      ));
  return id;
}

Future<String> _insertBatch(
  db_lib.AppDatabase db, {
  required String productId,
  required int quantity,
  String? id,
  DateTime? expiryDate,
  String status = 'active',
}) async {
  final batchId = id ?? 'batch-${DateTime.now().microsecondsSinceEpoch}';
  await db.into(db.batches).insert(db_lib.BatchesCompanion.insert(
        id: batchId,
        productId: productId,
        batchNumber: 'LOT001',
        expiryDate:
            expiryDate ?? DateTime.now().add(const Duration(days: 365)),
        supplierName: 'Supplier A',
        quantityReceived: quantity,
        quantityRemaining: quantity,
        costPricePerUnit: 200,
        status: Value(status),
      ));
  return batchId;
}

/// Insert a sale row directly with a custom recordedAt timestamp.
Future<String> _insertSaleRow(
  db_lib.AppDatabase db, {
  required String userId,
  required DateTime recordedAt,
  bool voided = false,
  String? voidReason,
}) async {
  final saleId = 'sale-${DateTime.now().microsecondsSinceEpoch}';
  await db.into(db.sales).insert(db_lib.SalesCompanion.insert(
        id: saleId,
        userId: userId,
        recordedAt: Value(recordedAt),
        totalZmw: 500,
        paymentMethod: 'Cash',
        voided: Value(voided),
        voidReason: Value(voidReason),
      ));
  return saleId;
}

/// Insert a sale item row linking a sale to a batch.
Future<void> _insertSaleItemRow(
  db_lib.AppDatabase db, {
  required String saleId,
  required String productId,
  required String batchId,
  required int quantity,
}) async {
  await db.into(db.saleItems).insert(db_lib.SaleItemsCompanion.insert(
        id: 'si-${DateTime.now().microsecondsSinceEpoch}',
        saleId: saleId,
        productId: productId,
        batchId: batchId,
        quantity: quantity,
        unitPrice: 500,
        lineTotal: quantity * 500,
      ));
}

Future<int> _batchQuantity(db_lib.AppDatabase db, String batchId) async {
  final row = await (db.select(db.batches)
        ..where((b) => b.id.equals(batchId)))
      .getSingle();
  return row.quantityRemaining;
}

void main() {
  group('SaleRepositoryImpl.voidSale', () {
    late db_lib.AppDatabase db;
    late SaleRepositoryImpl repo;

    setUp(() {
      db = _openTestDb();
      repo = SaleRepositoryImpl(db);
    });

    tearDown(() async {
      await db.close();
    });

    // -------------------------------------------------------------------------
    // Void a same-day sale successfully
    // -------------------------------------------------------------------------

    test('voids a same-day sale successfully', () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);
      final batchId =
          await _insertBatch(db, productId: productId, quantity: 20, id: 'b1');

      final saleId = await _insertSaleRow(db,
          userId: userId, recordedAt: DateTime.now());
      await _insertSaleItemRow(db,
          saleId: saleId,
          productId: productId,
          batchId: batchId,
          quantity: 5);

      // Should complete without throwing.
      await expectLater(
        repo.voidSale(saleId, 'Customer returned items'),
        completes,
      );
    });

    // -------------------------------------------------------------------------
    // Sale is marked as voided in DB
    // -------------------------------------------------------------------------

    test('sale is marked as voided in the database', () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);
      final batchId =
          await _insertBatch(db, productId: productId, quantity: 20, id: 'b1');

      final saleId = await _insertSaleRow(db,
          userId: userId, recordedAt: DateTime.now());
      await _insertSaleItemRow(db,
          saleId: saleId,
          productId: productId,
          batchId: batchId,
          quantity: 5);

      await repo.voidSale(saleId, 'Duplicate entry');

      final row = await (db.select(db.sales)
            ..where((s) => s.id.equals(saleId)))
          .getSingle();

      expect(row.voided, isTrue);
      expect(row.voidReason, equals('Duplicate entry'));
      expect(row.voidedAt, isA<DateTime>());
    });

    // -------------------------------------------------------------------------
    // Stock is restored after void
    // -------------------------------------------------------------------------

    test('stock is restored after void', () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);
      final batchId =
          await _insertBatch(db, productId: productId, quantity: 20, id: 'b1');

      final saleId = await _insertSaleRow(db,
          userId: userId, recordedAt: DateTime.now());
      await _insertSaleItemRow(db,
          saleId: saleId,
          productId: productId,
          batchId: batchId,
          quantity: 7);

      // Simulate stock already decremented by the sale.
      await (db.update(db.batches)..where((b) => b.id.equals(batchId)))
          .write(const db_lib.BatchesCompanion(
              quantityRemaining: Value(13))); // 20 - 7

      await repo.voidSale(saleId, 'Error in sale');

      expect(await _batchQuantity(db, batchId), equals(20));
    });

    // -------------------------------------------------------------------------
    // Reject void for previous-day sale
    // -------------------------------------------------------------------------

    test('rejects void for a sale recorded on a previous day', () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);
      final batchId =
          await _insertBatch(db, productId: productId, quantity: 20, id: 'b1');

      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      final saleId = await _insertSaleRow(db,
          userId: userId, recordedAt: yesterday);
      await _insertSaleItemRow(db,
          saleId: saleId,
          productId: productId,
          batchId: batchId,
          quantity: 5);

      expect(
        () => repo.voidSale(saleId, 'Late void attempt'),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          'Sales can only be voided on the day they were recorded',
        )),
      );
    });

    // -------------------------------------------------------------------------
    // Reject void for already-voided sale
    // -------------------------------------------------------------------------

    test('rejects void for an already-voided sale', () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);
      final batchId =
          await _insertBatch(db, productId: productId, quantity: 20, id: 'b1');

      final saleId = await _insertSaleRow(db,
          userId: userId,
          recordedAt: DateTime.now(),
          voided: true,
          voidReason: 'Already voided');
      await _insertSaleItemRow(db,
          saleId: saleId,
          productId: productId,
          batchId: batchId,
          quantity: 5);

      expect(
        () => repo.voidSale(saleId, 'Trying again'),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          'Sale is already voided',
        )),
      );
    });

    // -------------------------------------------------------------------------
    // Reject void with empty reason
    // -------------------------------------------------------------------------

    test('rejects void with empty reason', () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);
      final batchId =
          await _insertBatch(db, productId: productId, quantity: 20, id: 'b1');

      final saleId = await _insertSaleRow(db,
          userId: userId, recordedAt: DateTime.now());
      await _insertSaleItemRow(db,
          saleId: saleId,
          productId: productId,
          batchId: batchId,
          quantity: 5);

      expect(
        () => repo.voidSale(saleId, ''),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          'Void reason is required',
        )),
      );
    });

    test('rejects void with whitespace-only reason', () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);
      final batchId =
          await _insertBatch(db, productId: productId, quantity: 20, id: 'b1');

      final saleId = await _insertSaleRow(db,
          userId: userId, recordedAt: DateTime.now());
      await _insertSaleItemRow(db,
          saleId: saleId,
          productId: productId,
          batchId: batchId,
          quantity: 5);

      expect(
        () => repo.voidSale(saleId, '   '),
        throwsA(isA<ArgumentError>()),
      );
    });

    // -------------------------------------------------------------------------
    // Throw StateError for unknown sale ID
    // -------------------------------------------------------------------------

    test('throws StateError when sale is not found', () async {
      expect(
        () => repo.voidSale('non-existent-id', 'Some reason'),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Sale not found'),
        )),
      );
    });
  });
}
