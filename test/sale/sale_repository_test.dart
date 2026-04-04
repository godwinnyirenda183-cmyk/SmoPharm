import 'package:drift/drift.dart' hide Batch;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_pos/data/repositories/sale_repository_impl.dart';
import 'package:pharmacy_pos/database/database.dart' as db_lib;
import 'package:pharmacy_pos/domain/entities/sale.dart';

db_lib.AppDatabase _openTestDb() =>
    db_lib.AppDatabase.forTesting(NativeDatabase.memory());

/// Insert a minimal user row (required by FK).
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

/// Insert a minimal product row (required by FK).
Future<String> _insertProduct(
  db_lib.AppDatabase db, {
  String id = 'prod-1',
  String name = 'Paracetamol',
  int sellingPrice = 500, // 5.00 ZMW in cents
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
  group('SaleRepositoryImpl', () {
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
    // Create sale with single item decrements stock
    // -------------------------------------------------------------------------

    test('create sale with single item decrements stock', () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);
      await _insertBatch(db, productId: productId, quantity: 50);

      final before = await _stockLevel(db, productId);
      expect(before, equals(50));

      await repo.create(SaleInput(
        userId: userId,
        paymentMethod: PaymentMethod.cash,
        items: [SaleItemInput(productId: productId, quantity: 10)],
      ));

      final after = await _stockLevel(db, productId);
      expect(after, equals(40));
    });

    // -------------------------------------------------------------------------
    // Create sale with multiple items decrements each product's stock
    // -------------------------------------------------------------------------

    test('create sale with multiple items decrements each product stock',
        () async {
      final userId = await _insertUser(db);
      final prodA = await _insertProduct(db,
          id: 'prod-a', name: 'Amoxicillin', sellingPrice: 1000);
      final prodB = await _insertProduct(db,
          id: 'prod-b', name: 'Ibuprofen', sellingPrice: 750);
      await _insertBatch(db,
          productId: prodA, quantity: 30, id: 'batch-a');
      await _insertBatch(db,
          productId: prodB, quantity: 20, id: 'batch-b');

      await repo.create(SaleInput(
        userId: userId,
        paymentMethod: PaymentMethod.mobileMoney,
        items: [
          SaleItemInput(productId: prodA, quantity: 5),
          SaleItemInput(productId: prodB, quantity: 8),
        ],
      ));

      expect(await _stockLevel(db, prodA), equals(25));
      expect(await _stockLevel(db, prodB), equals(12));
    });

    // -------------------------------------------------------------------------
    // Reject sale item when quantity > stock level
    // -------------------------------------------------------------------------

    test('rejects sale when quantity exceeds stock level', () async {
      final userId = await _insertUser(db);
      final productId =
          await _insertProduct(db, name: 'Metformin');
      await _insertBatch(db, productId: productId, quantity: 5);

      expect(
        () => repo.create(SaleInput(
          userId: userId,
          paymentMethod: PaymentMethod.cash,
          items: [SaleItemInput(productId: productId, quantity: 10)],
        )),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          'Insufficient stock for Metformin',
        )),
      );
    });

    test('stock level is unchanged after rejected sale', () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db, name: 'Aspirin');
      await _insertBatch(db, productId: productId, quantity: 5);

      try {
        await repo.create(SaleInput(
          userId: userId,
          paymentMethod: PaymentMethod.cash,
          items: [SaleItemInput(productId: productId, quantity: 100)],
        ));
      } catch (_) {}

      expect(await _stockLevel(db, productId), equals(5));
    });

    // -------------------------------------------------------------------------
    // Sale total equals sum of line totals
    // -------------------------------------------------------------------------

    test('sale total equals sum of line totals (integer cents)', () async {
      final userId = await _insertUser(db);
      // Product A: 1000 cents (ZMW 10.00), qty 3 → line total 3000
      // Product B: 750 cents (ZMW 7.50), qty 2 → line total 1500
      // Expected total: 4500 cents
      final prodA = await _insertProduct(db,
          id: 'prod-a', name: 'Drug A', sellingPrice: 1000);
      final prodB = await _insertProduct(db,
          id: 'prod-b', name: 'Drug B', sellingPrice: 750);
      await _insertBatch(db, productId: prodA, quantity: 20, id: 'ba');
      await _insertBatch(db, productId: prodB, quantity: 20, id: 'bb');

      final sale = await repo.create(SaleInput(
        userId: userId,
        paymentMethod: PaymentMethod.insurance,
        items: [
          SaleItemInput(productId: prodA, quantity: 3),
          SaleItemInput(productId: prodB, quantity: 2),
        ],
      ));

      expect(sale.totalZmw, equals(4500));
      expect(sale.items[0].lineTotal, equals(3000));
      expect(sale.items[1].lineTotal, equals(1500));
    });

    test('sale total is persisted correctly in the database', () async {
      final userId = await _insertUser(db);
      final productId =
          await _insertProduct(db, sellingPrice: 200); // 2.00 ZMW
      await _insertBatch(db, productId: productId, quantity: 50);

      final sale = await repo.create(SaleInput(
        userId: userId,
        paymentMethod: PaymentMethod.cash,
        items: [SaleItemInput(productId: productId, quantity: 4)],
      ));

      // 4 * 200 = 800 cents
      expect(sale.totalZmw, equals(800));

      final row = await (db.select(db.sales)
            ..where((s) => s.id.equals(sale.id)))
          .getSingle();
      expect(row.totalZmw, equals(800));
    });

    // -------------------------------------------------------------------------
    // Records payment method and timestamp
    // -------------------------------------------------------------------------

    test('records payment method Cash', () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);
      await _insertBatch(db, productId: productId, quantity: 20);

      final sale = await repo.create(SaleInput(
        userId: userId,
        paymentMethod: PaymentMethod.cash,
        items: [SaleItemInput(productId: productId, quantity: 1)],
      ));

      expect(sale.paymentMethod, equals(PaymentMethod.cash));

      final row = await (db.select(db.sales)
            ..where((s) => s.id.equals(sale.id)))
          .getSingle();
      expect(row.paymentMethod, equals('Cash'));
    });

    test('records payment method Mobile_Money', () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);
      await _insertBatch(db, productId: productId, quantity: 20);

      final sale = await repo.create(SaleInput(
        userId: userId,
        paymentMethod: PaymentMethod.mobileMoney,
        items: [SaleItemInput(productId: productId, quantity: 1)],
      ));

      expect(sale.paymentMethod, equals(PaymentMethod.mobileMoney));

      final row = await (db.select(db.sales)
            ..where((s) => s.id.equals(sale.id)))
          .getSingle();
      expect(row.paymentMethod, equals('Mobile_Money'));
    });

    test('records payment method Insurance', () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);
      await _insertBatch(db, productId: productId, quantity: 20);

      final sale = await repo.create(SaleInput(
        userId: userId,
        paymentMethod: PaymentMethod.insurance,
        items: [SaleItemInput(productId: productId, quantity: 1)],
      ));

      expect(sale.paymentMethod, equals(PaymentMethod.insurance));

      final row = await (db.select(db.sales)
            ..where((s) => s.id.equals(sale.id)))
          .getSingle();
      expect(row.paymentMethod, equals('Insurance'));
    });

    test('records a timestamp on the sale record', () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);
      await _insertBatch(db, productId: productId, quantity: 20);

      final before = DateTime.now().subtract(const Duration(seconds: 1));

      final sale = await repo.create(SaleInput(
        userId: userId,
        paymentMethod: PaymentMethod.cash,
        items: [SaleItemInput(productId: productId, quantity: 1)],
      ));

      final after = DateTime.now().add(const Duration(seconds: 1));

      expect(sale.recordedAt.isAfter(before), isTrue);
      expect(sale.recordedAt.isBefore(after), isTrue);
    });

    test('records user ID on the sale record', () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);
      await _insertBatch(db, productId: productId, quantity: 20);

      final sale = await repo.create(SaleInput(
        userId: userId,
        paymentMethod: PaymentMethod.cash,
        items: [SaleItemInput(productId: productId, quantity: 1)],
      ));

      expect(sale.userId, equals(userId));

      final row = await (db.select(db.sales)
            ..where((s) => s.id.equals(sale.id)))
          .getSingle();
      expect(row.userId, equals(userId));
    });

    // -------------------------------------------------------------------------
    // FEFO batch selection: earliest expiry batch is decremented first
    // -------------------------------------------------------------------------

    test('FEFO: earliest expiry batch is decremented first', () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);

      // Earlier expiry batch (should be selected by FEFO).
      await _insertBatch(
        db,
        productId: productId,
        quantity: 20,
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

      await repo.create(SaleInput(
        userId: userId,
        paymentMethod: PaymentMethod.cash,
        items: [SaleItemInput(productId: productId, quantity: 5)],
      ));

      final earlyBatch = await (db.select(db.batches)
            ..where((b) => b.id.equals('batch-early')))
          .getSingle();
      final lateBatch = await (db.select(db.batches)
            ..where((b) => b.id.equals('batch-late')))
          .getSingle();

      // FEFO: early batch decremented, late batch untouched.
      expect(earlyBatch.quantityRemaining, equals(15));
      expect(lateBatch.quantityRemaining, equals(20));
    });

    test('FEFO: sale item references the earliest expiry batch', () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);

      await _insertBatch(
        db,
        productId: productId,
        quantity: 20,
        id: 'batch-early',
        batchNumber: 'EARLY',
        expiryDate: DateTime.now().add(const Duration(days: 30)),
      );
      await _insertBatch(
        db,
        productId: productId,
        quantity: 20,
        id: 'batch-late',
        batchNumber: 'LATE',
        expiryDate: DateTime.now().add(const Duration(days: 200)),
      );

      final sale = await repo.create(SaleInput(
        userId: userId,
        paymentMethod: PaymentMethod.cash,
        items: [SaleItemInput(productId: productId, quantity: 5)],
      ));

      expect(sale.items.first.batchId, equals('batch-early'));
    });

    // -------------------------------------------------------------------------
    // voided defaults to false
    // -------------------------------------------------------------------------

    test('new sale is not voided', () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);
      await _insertBatch(db, productId: productId, quantity: 20);

      final sale = await repo.create(SaleInput(
        userId: userId,
        paymentMethod: PaymentMethod.cash,
        items: [SaleItemInput(productId: productId, quantity: 1)],
      ));

      expect(sale.voided, isFalse);

      final row = await (db.select(db.sales)
            ..where((s) => s.id.equals(sale.id)))
          .getSingle();
      expect(row.voided, isFalse);
    });
  });
}
