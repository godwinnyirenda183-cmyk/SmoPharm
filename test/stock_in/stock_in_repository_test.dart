import 'package:drift/drift.dart' hide StockIn, StockInLine;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_pos/data/repositories/stock_in_repository_impl.dart';
import 'package:pharmacy_pos/database/database.dart' hide StockIn, StockInLine;
import 'package:pharmacy_pos/domain/entities/batch.dart';
import 'package:pharmacy_pos/domain/repositories/stock_in_repository.dart';

AppDatabase _openTestDb() => AppDatabase.forTesting(NativeDatabase.memory());

/// Insert a minimal user row (required by StockIn FK).
Future<String> _insertUser(AppDatabase db, {String id = 'user-1'}) async {
  await db.into(db.users).insert(UsersCompanion.insert(
        id: id,
        username: 'pharmacist_$id',
        passwordHash: 'hash',
        role: 'admin',
      ));
  return id;
}

/// Insert a minimal product row (required by Batch FK).
Future<String> _insertProduct(AppDatabase db, {String id = 'prod-1'}) async {
  await db.into(db.products).insert(ProductsCompanion.insert(
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

/// Build a [StockInBatchInput] for a given product.
StockInBatchInput _batchInput({
  required String productId,
  int quantity = 50,
  String batchNumber = 'LOT001',
  DateTime? expiryDate,
}) =>
    StockInBatchInput(
      batchInput: BatchInput(
        productId: productId,
        batchNumber: batchNumber,
        expiryDate: expiryDate ?? DateTime.now().add(const Duration(days: 365)),
        supplierName: 'Supplier A',
        quantityReceived: quantity,
        costPricePerUnit: 200,
      ),
      quantity: quantity,
    );

/// Compute stock level for a product (sum of non-expired batch quantities).
Future<int> _stockLevel(AppDatabase db, String productId) async {
  final batches = await (db.select(db.batches)
        ..where((b) =>
            b.productId.equals(productId) &
            b.status.isNotIn(const ['expired'])))
      .get();
  return batches.fold<int>(0, (sum, b) => sum + b.quantityRemaining);
}

void main() {
  group('StockInRepositoryImpl', () {
    late AppDatabase db;
    late StockInRepositoryImpl repo;

    setUp(() {
      db = _openTestDb();
      repo = StockInRepositoryImpl(db);
    });

    tearDown(() async {
      await db.close();
    });

    // -------------------------------------------------------------------------
    // Single-line stock-in
    // -------------------------------------------------------------------------

    test('create with single line increases stock level for the product',
        () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);

      final stockBefore = await _stockLevel(db, productId);

      await repo.create(StockInCreateInput(
        userId: userId,
        batches: [_batchInput(productId: productId, quantity: 50)],
      ));

      final stockAfter = await _stockLevel(db, productId);
      expect(stockAfter, equals(stockBefore + 50));
    });

    // -------------------------------------------------------------------------
    // Multi-line stock-in
    // -------------------------------------------------------------------------

    test('create with multiple lines increases stock for each product',
        () async {
      final userId = await _insertUser(db);
      final prodA = await _insertProduct(db, id: 'prod-a');
      final prodB = await _insertProduct(db, id: 'prod-b');

      await repo.create(StockInCreateInput(
        userId: userId,
        batches: [
          _batchInput(productId: prodA, quantity: 30, batchNumber: 'LOT-A'),
          _batchInput(productId: prodB, quantity: 20, batchNumber: 'LOT-B'),
        ],
      ));

      expect(await _stockLevel(db, prodA), equals(30));
      expect(await _stockLevel(db, prodB), equals(20));
    });

    // -------------------------------------------------------------------------
    // Quantity validation
    // -------------------------------------------------------------------------

    test('create throws ArgumentError when any quantity is zero', () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);

      expect(
        () => repo.create(StockInCreateInput(
          userId: userId,
          batches: [_batchInput(productId: productId, quantity: 0)],
        )),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          'Quantity must be greater than zero',
        )),
      );
    });

    test('create throws ArgumentError when any quantity is negative', () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);

      expect(
        () => repo.create(StockInCreateInput(
          userId: userId,
          batches: [_batchInput(productId: productId, quantity: -5)],
        )),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          'Quantity must be greater than zero',
        )),
      );
    });

    test(
        'create throws ArgumentError when one of multiple lines has quantity ≤ 0',
        () async {
      final userId = await _insertUser(db);
      final prodA = await _insertProduct(db, id: 'prod-a');
      final prodB = await _insertProduct(db, id: 'prod-b');

      expect(
        () => repo.create(StockInCreateInput(
          userId: userId,
          batches: [
            _batchInput(productId: prodA, quantity: 10, batchNumber: 'LOT-A'),
            _batchInput(productId: prodB, quantity: 0, batchNumber: 'LOT-B'),
          ],
        )),
        throwsA(isA<ArgumentError>()),
      );
    });

    // -------------------------------------------------------------------------
    // User ID and timestamp recording
    // -------------------------------------------------------------------------

    test('create records the user ID on the StockIn record', () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);

      final stockIn = await repo.create(StockInCreateInput(
        userId: userId,
        batches: [_batchInput(productId: productId)],
      ));

      expect(stockIn.userId, equals(userId));

      // Verify persisted in DB.
      final row = await (db.select(db.stockIns)
            ..where((s) => s.id.equals(stockIn.id)))
          .getSingle();
      expect(row.userId, equals(userId));
    });

    test('create records a timestamp on the StockIn record', () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);

      final before = DateTime.now().subtract(const Duration(seconds: 1));

      final stockIn = await repo.create(StockInCreateInput(
        userId: userId,
        batches: [_batchInput(productId: productId)],
      ));

      final after = DateTime.now().add(const Duration(seconds: 1));

      expect(stockIn.recordedAt.isAfter(before), isTrue);
      expect(stockIn.recordedAt.isBefore(after), isTrue);
    });

    // -------------------------------------------------------------------------
    // Exact quantity increase
    // -------------------------------------------------------------------------

    test('stock level increases by exactly the quantity received', () async {
      final userId = await _insertUser(db);
      final productId = await _insertProduct(db);

      // Pre-existing batch to establish a baseline stock level.
      await db.into(db.batches).insert(BatchesCompanion.insert(
            id: 'existing-batch',
            productId: productId,
            batchNumber: 'EXISTING',
            expiryDate: DateTime.now().add(const Duration(days: 200)),
            supplierName: 'Old Supplier',
            quantityReceived: 100,
            quantityRemaining: 100,
            costPricePerUnit: 150,
          ));

      final stockBefore = await _stockLevel(db, productId);
      expect(stockBefore, equals(100));

      await repo.create(StockInCreateInput(
        userId: userId,
        batches: [_batchInput(productId: productId, quantity: 75)],
      ));

      final stockAfter = await _stockLevel(db, productId);
      expect(stockAfter, equals(stockBefore + 75));
    });

    // -------------------------------------------------------------------------
    // Return value structure
    // -------------------------------------------------------------------------

    test('create returns StockIn with correct number of lines', () async {
      final userId = await _insertUser(db);
      final prodA = await _insertProduct(db, id: 'prod-a');
      final prodB = await _insertProduct(db, id: 'prod-b');

      final stockIn = await repo.create(StockInCreateInput(
        userId: userId,
        batches: [
          _batchInput(productId: prodA, quantity: 10, batchNumber: 'LOT-A'),
          _batchInput(productId: prodB, quantity: 20, batchNumber: 'LOT-B'),
        ],
      ));

      expect(stockIn.lines, hasLength(2));
      expect(stockIn.lines.map((l) => l.quantity).toList(),
          containsAll([10, 20]));
    });
  });
}
