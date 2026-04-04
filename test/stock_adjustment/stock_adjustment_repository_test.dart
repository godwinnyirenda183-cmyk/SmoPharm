import 'package:drift/drift.dart' hide Batch;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_pos/data/repositories/stock_adjustment_repository_impl.dart';
import 'package:pharmacy_pos/database/database.dart' as db_lib;
import 'package:pharmacy_pos/domain/entities/stock_adjustment.dart';

db_lib.AppDatabase _openTestDb() =>
    db_lib.AppDatabase.forTesting(NativeDatabase.memory());

/// Insert a minimal user row (required by FK).
Future<String> _insertUser(db_lib.AppDatabase db,
    {String id = 'user-1'}) async {
  await db.into(db.users).insert(db_lib.UsersCompanion.insert(
        id: id,
        username: 'pharmacist_$id',
        passwordHash: 'hash',
        role: 'admin',
      ));
  return id;
}

/// Insert a minimal product row (required by FK).
Future<String> _insertProduct(db_lib.AppDatabase db,
    {String id = 'prod-1'}) async {
  await db.into(db.products).insert(db_lib.ProductsCompanion.insert(
        id: id,
        name: 'Product $id',
        genericName: 'Generic $id',
        category: 'Category',
        unitOfMeasure: 'Tablet',
        sellingPrice: 500,
        lowStockThreshold: 10,
      ));
  return id;
}

/// Insert a batch with a given quantity for a product.
Future<String> _insertBatch(
  db_lib.AppDatabase db, {
  required String productId,
  required int quantity,
  String? id,
  String batchNumber = 'LOT001',
  DateTime? expiryDate,
  String status = 'active',
}) async {
  final batchId = id ?? 'batch-${DateTime.now().microsecondsSinceEpoch}';
  await db.into(db.batches).insert(db_lib.BatchesCompanion.insert(
        id: batchId,
        productId: productId,
        batchNumber: batchNumber,
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

/// Compute stock level for a product (sum of non-expired batch quantities).
Future<int> _stockLevel(db_lib.AppDatabase db, String productId) async {
  final batches = await (db.select(db.batches)
        ..where((b) =>
            b.productId.equals(productId) &
            b.status.isNotIn(const ['expired'])))
      .get();
  return batches.fold<int>(0, (sum, b) => sum + b.quantityRemaining);
}

void main() {
  group('StockAdjustmentRepositoryImpl', () {
    late db_lib.AppDatabase db;
    late StockAdjustmentRepositoryImpl repo;

    setUp(() {
      db = _openTestDb();
      repo = StockAdjustmentRepositoryImpl(db);
    });

    tearDown(() async {
      await db.close();
    });

    // -------------------------------------------------------------------------
    // Positive adjustment increases stock level
    // -------------------------------------------------------------------------

    test('positive adjustment increases stock level', () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);
      await _insertBatch(db, productId: productId, quantity: 50);

      final before = await _stockLevel(db, productId);
      expect(before, equals(50));

      await repo.create(StockAdjustmentInput(
        productId: productId,
        userId: userId,
        quantityDelta: 20,
        reasonCode: AdjustmentReasonCode.countCorrection,
      ));

      final after = await _stockLevel(db, productId);
      expect(after, equals(70));
    });

    // -------------------------------------------------------------------------
    // Negative adjustment decreases stock level
    // -------------------------------------------------------------------------

    test('negative adjustment decreases stock level', () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);
      await _insertBatch(db, productId: productId, quantity: 50);

      await repo.create(StockAdjustmentInput(
        productId: productId,
        userId: userId,
        quantityDelta: -15,
        reasonCode: AdjustmentReasonCode.damaged,
      ));

      final after = await _stockLevel(db, productId);
      expect(after, equals(35));
    });

    // -------------------------------------------------------------------------
    // Reject adjustment that would make stock negative
    // -------------------------------------------------------------------------

    test('rejects adjustment that would result in negative stock', () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);
      await _insertBatch(db, productId: productId, quantity: 10);

      expect(
        () => repo.create(StockAdjustmentInput(
          productId: productId,
          userId: userId,
          quantityDelta: -11,
          reasonCode: AdjustmentReasonCode.damaged,
        )),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          'Adjustment would result in negative stock',
        )),
      );
    });

    test('stock level is unchanged after rejected negative adjustment',
        () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);
      await _insertBatch(db, productId: productId, quantity: 10);

      try {
        await repo.create(StockAdjustmentInput(
          productId: productId,
          userId: userId,
          quantityDelta: -20,
          reasonCode: AdjustmentReasonCode.damaged,
        ));
      } catch (_) {}

      expect(await _stockLevel(db, productId), equals(10));
    });

    // -------------------------------------------------------------------------
    // Records user ID and timestamp
    // -------------------------------------------------------------------------

    test('records user ID on the adjustment record', () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);
      await _insertBatch(db, productId: productId, quantity: 50);

      final adjustment = await repo.create(StockAdjustmentInput(
        productId: productId,
        userId: userId,
        quantityDelta: 5,
        reasonCode: AdjustmentReasonCode.other,
      ));

      expect(adjustment.userId, equals(userId));

      // Verify persisted in DB.
      final row = await (db.select(db.stockAdjustments)
            ..where((a) => a.id.equals(adjustment.id)))
          .getSingle();
      expect(row.userId, equals(userId));
    });

    test('records a timestamp on the adjustment record', () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);
      await _insertBatch(db, productId: productId, quantity: 50);

      final before = DateTime.now().subtract(const Duration(seconds: 1));

      final adjustment = await repo.create(StockAdjustmentInput(
        productId: productId,
        userId: userId,
        quantityDelta: 5,
        reasonCode: AdjustmentReasonCode.other,
      ));

      final after = DateTime.now().add(const Duration(seconds: 1));

      expect(adjustment.recordedAt.isAfter(before), isTrue);
      expect(adjustment.recordedAt.isBefore(after), isTrue);
    });

    // -------------------------------------------------------------------------
    // Audit log (listForProduct) returns all adjustments
    // -------------------------------------------------------------------------

    test('listForProduct returns all adjustments for a product', () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);
      await _insertBatch(db, productId: productId, quantity: 100);

      await repo.create(StockAdjustmentInput(
        productId: productId,
        userId: userId,
        quantityDelta: 10,
        reasonCode: AdjustmentReasonCode.countCorrection,
      ));
      await repo.create(StockAdjustmentInput(
        productId: productId,
        userId: userId,
        quantityDelta: -5,
        reasonCode: AdjustmentReasonCode.damaged,
      ));

      final log = await repo.listForProduct(productId);
      expect(log, hasLength(2));
    });

    test('listForProduct returns empty list when no adjustments exist',
        () async {
      final productId = await _insertProduct(db);
      final log = await repo.listForProduct(productId);
      expect(log, isEmpty);
    });

    test('listForProduct does not return adjustments for other products',
        () async {
      final userId = await _insertUser(db);
      final prodA = await _insertProduct(db, id: 'prod-a');
      final prodB = await _insertProduct(db, id: 'prod-b');
      await _insertBatch(db, productId: prodA, quantity: 50, id: 'batch-a');
      await _insertBatch(db, productId: prodB, quantity: 50, id: 'batch-b');

      await repo.create(StockAdjustmentInput(
        productId: prodA,
        userId: userId,
        quantityDelta: 5,
        reasonCode: AdjustmentReasonCode.other,
      ));

      final logB = await repo.listForProduct(prodB);
      expect(logB, isEmpty);
    });

    // -------------------------------------------------------------------------
    // Reason code: Damaged
    // -------------------------------------------------------------------------

    test('adjustment with reason code Damaged is persisted correctly',
        () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);
      await _insertBatch(db, productId: productId, quantity: 30);

      final adjustment = await repo.create(StockAdjustmentInput(
        productId: productId,
        userId: userId,
        quantityDelta: -5,
        reasonCode: AdjustmentReasonCode.damaged,
      ));

      expect(adjustment.reasonCode, equals(AdjustmentReasonCode.damaged));

      final row = await (db.select(db.stockAdjustments)
            ..where((a) => a.id.equals(adjustment.id)))
          .getSingle();
      expect(row.reasonCode, equals('Damaged'));
    });

    // -------------------------------------------------------------------------
    // Reason code: Expired_Removal
    // -------------------------------------------------------------------------

    test('adjustment with reason code Expired_Removal is persisted correctly',
        () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);
      await _insertBatch(db, productId: productId, quantity: 30);

      final adjustment = await repo.create(StockAdjustmentInput(
        productId: productId,
        userId: userId,
        quantityDelta: -10,
        reasonCode: AdjustmentReasonCode.expiredRemoval,
      ));

      expect(
          adjustment.reasonCode, equals(AdjustmentReasonCode.expiredRemoval));

      final row = await (db.select(db.stockAdjustments)
            ..where((a) => a.id.equals(adjustment.id)))
          .getSingle();
      expect(row.reasonCode, equals('Expired_Removal'));
    });

    // -------------------------------------------------------------------------
    // FEFO: negative delta spans multiple batches
    // -------------------------------------------------------------------------

    test('negative delta is applied across multiple batches in FEFO order',
        () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);

      // Earlier expiry batch (should be depleted first).
      await _insertBatch(
        db,
        productId: productId,
        quantity: 10,
        id: 'batch-early',
        batchNumber: 'EARLY',
        expiryDate: DateTime.now().add(const Duration(days: 30)),
      );
      // Later expiry batch.
      await _insertBatch(
        db,
        productId: productId,
        quantity: 20,
        id: 'batch-late',
        batchNumber: 'LATE',
        expiryDate: DateTime.now().add(const Duration(days: 200)),
      );

      // Remove 15 units: should exhaust early batch (10) then take 5 from late.
      await repo.create(StockAdjustmentInput(
        productId: productId,
        userId: userId,
        quantityDelta: -15,
        reasonCode: AdjustmentReasonCode.damaged,
      ));

      final earlyBatch = await (db.select(db.batches)
            ..where((b) => b.id.equals('batch-early')))
          .getSingle();
      final lateBatch = await (db.select(db.batches)
            ..where((b) => b.id.equals('batch-late')))
          .getSingle();

      expect(earlyBatch.quantityRemaining, equals(0));
      expect(lateBatch.quantityRemaining, equals(15));
    });

    // -------------------------------------------------------------------------
    // Exact-zero adjustment is accepted
    // -------------------------------------------------------------------------

    test('adjustment that brings stock to exactly zero is accepted', () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);
      await _insertBatch(db, productId: productId, quantity: 10);

      final adjustment = await repo.create(StockAdjustmentInput(
        productId: productId,
        userId: userId,
        quantityDelta: -10,
        reasonCode: AdjustmentReasonCode.countCorrection,
      ));

      expect(adjustment.quantityDelta, equals(-10));
      expect(await _stockLevel(db, productId), equals(0));
    });
  });
}
