import 'package:drift/drift.dart' hide Batch, isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_pos/data/repositories/batch_repository_impl.dart';
import 'package:pharmacy_pos/database/database.dart';
import 'package:pharmacy_pos/domain/entities/batch.dart';

AppDatabase _openTestDb() => AppDatabase.forTesting(NativeDatabase.memory());

/// Helper to create a product row directly in the DB (needed for FK).
Future<String> _insertProduct(AppDatabase db, {String id = 'prod-1'}) async {
  await db.into(db.products).insert(ProductsCompanion.insert(
        id: id,
        name: 'Test Product',
        genericName: 'Generic',
        category: 'Category',
        unitOfMeasure: 'Tablet',
        sellingPrice: 500,
        lowStockThreshold: 10,
      ));
  return id;
}

/// Helper to build a [BatchInput].
BatchInput _input({
  required String productId,
  required DateTime expiryDate,
  String batchNumber = 'LOT001',
  String supplierName = 'Supplier A',
  int quantityReceived = 100,
  int costPricePerUnit = 200,
}) =>
    BatchInput(
      productId: productId,
      batchNumber: batchNumber,
      expiryDate: expiryDate,
      supplierName: supplierName,
      quantityReceived: quantityReceived,
      costPricePerUnit: costPricePerUnit,
    );

void main() {
  group('BatchRepositoryImpl', () {
    late AppDatabase db;
    late BatchRepositoryImpl repo;

    setUp(() {
      db = _openTestDb();
      repo = BatchRepositoryImpl(db);
    });

    tearDown(() async {
      await db.close();
    });

    // -------------------------------------------------------------------------
    // create — status computation
    // -------------------------------------------------------------------------

    test('create assigns active status when expiry is beyond the window',
        () async {
      final productId = await _insertProduct(db);
      final futureExpiry = DateTime.now().add(const Duration(days: 200));

      final batch = await repo.create(
        _input(productId: productId, expiryDate: futureExpiry),
        nearExpiryWindowDays: 90,
      );

      expect(batch.status, equals(BatchStatus.active));
    });

    test('create assigns near_expiry status when expiry is within the window',
        () async {
      final productId = await _insertProduct(db);
      // Expiry is 30 days from now, window is 90 days → near_expiry.
      final nearExpiry = DateTime.now().add(const Duration(days: 30));

      final batch = await repo.create(
        _input(productId: productId, expiryDate: nearExpiry),
        nearExpiryWindowDays: 90,
      );

      expect(batch.status, equals(BatchStatus.nearExpiry));
    });

    test('create assigns expired status when expiry date is in the past',
        () async {
      final productId = await _insertProduct(db);
      final pastExpiry = DateTime.now().subtract(const Duration(days: 1));

      final batch = await repo.create(
        _input(productId: productId, expiryDate: pastExpiry),
        nearExpiryWindowDays: 90,
      );

      expect(batch.status, equals(BatchStatus.expired));
    });

    test('create sets quantityRemaining equal to quantityReceived', () async {
      final productId = await _insertProduct(db);
      final expiry = DateTime.now().add(const Duration(days: 200));

      final batch = await repo.create(
        _input(productId: productId, expiryDate: expiry, quantityReceived: 50),
        nearExpiryWindowDays: 90,
      );

      expect(batch.quantityRemaining, equals(50));
    });

    // -------------------------------------------------------------------------
    // selectFEFO
    // -------------------------------------------------------------------------

    test('selectFEFO returns the batch with the earliest expiry date', () async {
      final productId = await _insertProduct(db);
      final earlier = DateTime.now().add(const Duration(days: 100));
      final later = DateTime.now().add(const Duration(days: 200));

      await repo.create(
        _input(productId: productId, expiryDate: later, batchNumber: 'LOT-B'),
        nearExpiryWindowDays: 90,
      );
      await repo.create(
        _input(productId: productId, expiryDate: earlier, batchNumber: 'LOT-A'),
        nearExpiryWindowDays: 90,
      );

      final selected = await repo.selectFEFO(productId, 1);

      expect(selected, isNotNull);
      expect(selected!.batchNumber, equals('LOT-A'));
    });

    test('selectFEFO returns null when no batch has sufficient stock', () async {
      final productId = await _insertProduct(db);
      final expiry = DateTime.now().add(const Duration(days: 100));

      await repo.create(
        _input(productId: productId, expiryDate: expiry, quantityReceived: 5),
        nearExpiryWindowDays: 90,
      );

      final selected = await repo.selectFEFO(productId, 10);

      expect(selected, isNull);
    });

    test('selectFEFO skips expired batches', () async {
      final productId = await _insertProduct(db);
      final pastExpiry = DateTime.now().subtract(const Duration(days: 1));
      final futureExpiry = DateTime.now().add(const Duration(days: 200));

      // Expired batch with plenty of stock.
      await repo.create(
        _input(
          productId: productId,
          expiryDate: pastExpiry,
          batchNumber: 'LOT-EXP',
          quantityReceived: 100,
        ),
        nearExpiryWindowDays: 90,
      );

      // Active batch with sufficient stock.
      await repo.create(
        _input(
          productId: productId,
          expiryDate: futureExpiry,
          batchNumber: 'LOT-ACT',
          quantityReceived: 50,
        ),
        nearExpiryWindowDays: 90,
      );

      final selected = await repo.selectFEFO(productId, 10);

      expect(selected, isNotNull);
      expect(selected!.batchNumber, equals('LOT-ACT'));
    });

    test('selectFEFO returns null when only expired batches exist', () async {
      final productId = await _insertProduct(db);
      final pastExpiry = DateTime.now().subtract(const Duration(days: 5));

      await repo.create(
        _input(productId: productId, expiryDate: pastExpiry, quantityReceived: 100),
        nearExpiryWindowDays: 90,
      );

      final selected = await repo.selectFEFO(productId, 1);

      expect(selected, isNull);
    });

    // -------------------------------------------------------------------------
    // nearExpiry
    // -------------------------------------------------------------------------

    test('nearExpiry returns only near_expiry batches', () async {
      final productId = await _insertProduct(db);

      // near_expiry: 30 days from now, window = 90
      final nearExpiryDate = DateTime.now().add(const Duration(days: 30));
      // active: 200 days from now
      final activeDate = DateTime.now().add(const Duration(days: 200));
      // expired: yesterday
      final expiredDate = DateTime.now().subtract(const Duration(days: 1));

      await repo.create(
        _input(productId: productId, expiryDate: nearExpiryDate, batchNumber: 'NEAR'),
        nearExpiryWindowDays: 90,
      );
      await repo.create(
        _input(productId: productId, expiryDate: activeDate, batchNumber: 'ACTIVE'),
        nearExpiryWindowDays: 90,
      );
      await repo.create(
        _input(productId: productId, expiryDate: expiredDate, batchNumber: 'EXP'),
        nearExpiryWindowDays: 90,
      );

      final result = await repo.nearExpiry(90);

      expect(result, hasLength(1));
      expect(result.first.batchNumber, equals('NEAR'));
      expect(result.first.status, equals(BatchStatus.nearExpiry));
    });

    test('nearExpiry returns empty list when no near_expiry batches exist',
        () async {
      final productId = await _insertProduct(db);
      final activeDate = DateTime.now().add(const Duration(days: 200));

      await repo.create(
        _input(productId: productId, expiryDate: activeDate),
        nearExpiryWindowDays: 90,
      );

      final result = await repo.nearExpiry(90);

      expect(result, isEmpty);
    });

    // -------------------------------------------------------------------------
    // expiredBatches
    // -------------------------------------------------------------------------

    test('expiredBatches returns only expired batches', () async {
      final productId = await _insertProduct(db);

      final expiredDate = DateTime.now().subtract(const Duration(days: 10));
      final activeDate = DateTime.now().add(const Duration(days: 200));

      await repo.create(
        _input(productId: productId, expiryDate: expiredDate, batchNumber: 'EXP'),
        nearExpiryWindowDays: 90,
      );
      await repo.create(
        _input(productId: productId, expiryDate: activeDate, batchNumber: 'ACT'),
        nearExpiryWindowDays: 90,
      );

      final result = await repo.expiredBatches();

      expect(result, hasLength(1));
      expect(result.first.batchNumber, equals('EXP'));
      expect(result.first.status, equals(BatchStatus.expired));
    });

    test('expiredBatches returns empty list when no expired batches exist',
        () async {
      final productId = await _insertProduct(db);
      final activeDate = DateTime.now().add(const Duration(days: 200));

      await repo.create(
        _input(productId: productId, expiryDate: activeDate),
        nearExpiryWindowDays: 90,
      );

      final result = await repo.expiredBatches();

      expect(result, isEmpty);
    });

    // -------------------------------------------------------------------------
    // Stock level (SUM of non-expired batches)
    // -------------------------------------------------------------------------

    test('stock level equals sum of non-expired batch quantities', () async {
      final productId = await _insertProduct(db);

      final activeDate = DateTime.now().add(const Duration(days: 200));
      final nearDate = DateTime.now().add(const Duration(days: 30));
      final expiredDate = DateTime.now().subtract(const Duration(days: 1));

      await repo.create(
        _input(productId: productId, expiryDate: activeDate, quantityReceived: 60, batchNumber: 'A'),
        nearExpiryWindowDays: 90,
      );
      await repo.create(
        _input(productId: productId, expiryDate: nearDate, quantityReceived: 40, batchNumber: 'B'),
        nearExpiryWindowDays: 90,
      );
      await repo.create(
        _input(productId: productId, expiryDate: expiredDate, quantityReceived: 20, batchNumber: 'C'),
        nearExpiryWindowDays: 90,
      );

      // Stock level = SUM(quantity_remaining) over non-expired batches = 60 + 40 = 100
      final nonExpiredBatches = await (db.select(db.batches)
            ..where((b) => b.productId.equals(productId) & b.status.isNotIn(const ['expired'])))
          .get();

      final stockLevel = nonExpiredBatches.fold<int>(0, (sum, b) => sum + b.quantityRemaining);

      expect(stockLevel, equals(100));
    });
  });
}
