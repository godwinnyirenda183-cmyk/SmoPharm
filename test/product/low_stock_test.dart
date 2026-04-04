// Feature: pharmacy-pos, Low-Stock Query
// Tests for ProductRepositoryImpl.listLowStock()
// Requirements: 6.1, 6.2, 6.3, 6.4

import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_pos/database/database.dart' hide Product;
import 'package:pharmacy_pos/data/repositories/product_repository_impl.dart';
import 'package:pharmacy_pos/domain/entities/product.dart';

AppDatabase _openTestDb() => AppDatabase.forTesting(NativeDatabase.memory());

ProductInput _input({
  String name = 'Product',
  int lowStockThreshold = 10,
}) =>
    ProductInput(
      name: name,
      genericName: name,
      category: 'General',
      unitOfMeasure: 'Tablet',
      sellingPrice: 500,
      lowStockThreshold: lowStockThreshold,
    );

/// Inserts an active batch with [quantity] remaining for [productId].
Future<void> _addBatch(
  AppDatabase db,
  String productId,
  int quantity, {
  String? id,
}) async {
  await db.into(db.batches).insert(BatchesCompanion.insert(
        id: id ?? 'batch-${productId.hashCode}-$quantity',
        productId: productId,
        batchNumber: 'LOT-$quantity',
        expiryDate: DateTime(2030, 1, 1),
        supplierName: 'Supplier',
        quantityReceived: quantity,
        quantityRemaining: quantity,
        costPricePerUnit: 100,
        status: const Value('active'),
      ));
}

void main() {
  group('ProductRepositoryImpl.listLowStock()', () {
    late AppDatabase db;
    late ProductRepositoryImpl repo;

    setUp(() {
      db = _openTestDb();
      repo = ProductRepositoryImpl(db);
    });

    tearDown(() async {
      await db.close();
    });

    // -------------------------------------------------------------------------
    // Requirement 6.1 / 6.3: products at or below threshold appear
    // -------------------------------------------------------------------------

    test('product with stock == threshold appears in low-stock list', () async {
      final p = await repo.create(_input(name: 'AtThreshold', lowStockThreshold: 10));
      await _addBatch(db, p.id, 10); // stock == threshold

      final list = await repo.listLowStock();
      expect(list.any((e) => e.product.id == p.id), isTrue);
    });

    test('product with stock below threshold appears in low-stock list',
        () async {
      final p = await repo.create(_input(name: 'BelowThreshold', lowStockThreshold: 10));
      await _addBatch(db, p.id, 5); // stock < threshold

      final list = await repo.listLowStock();
      expect(list.any((e) => e.product.id == p.id), isTrue);
    });

    test('product with zero stock appears in low-stock list', () async {
      final p = await repo.create(_input(name: 'ZeroStock', lowStockThreshold: 10));
      // No batches → stock == 0

      final list = await repo.listLowStock();
      expect(list.any((e) => e.product.id == p.id), isTrue);
    });

    // -------------------------------------------------------------------------
    // Requirement 6.1 / 6.3: products above threshold do NOT appear
    // -------------------------------------------------------------------------

    test('product with stock above threshold does NOT appear in low-stock list',
        () async {
      final p = await repo.create(_input(name: 'AboveThreshold', lowStockThreshold: 10));
      await _addBatch(db, p.id, 11); // stock > threshold

      final list = await repo.listLowStock();
      expect(list.any((e) => e.product.id == p.id), isFalse);
    });

    test('only low-stock products are returned when mix exists', () async {
      final low = await repo.create(_input(name: 'LowProduct', lowStockThreshold: 20));
      final ok = await repo.create(_input(name: 'OkProduct', lowStockThreshold: 20));

      await _addBatch(db, low.id, 5);  // 5 <= 20 → low stock
      await _addBatch(db, ok.id, 25); // 25 > 20 → not low stock

      final list = await repo.listLowStock();
      expect(list.any((e) => e.product.id == low.id), isTrue);
      expect(list.any((e) => e.product.id == ok.id), isFalse);
    });

    // -------------------------------------------------------------------------
    // Requirement 6.4: sorted by criticality ratio ascending
    // -------------------------------------------------------------------------

    test('list is sorted by (stock / threshold) ascending', () async {
      // ratio 0.5: stock=5, threshold=10
      final p1 = await repo.create(_input(name: 'Half', lowStockThreshold: 10));
      await _addBatch(db, p1.id, 5, id: 'b-half');

      // ratio 0.2: stock=2, threshold=10
      final p2 = await repo.create(_input(name: 'Critical', lowStockThreshold: 10));
      await _addBatch(db, p2.id, 2, id: 'b-crit');

      // ratio 1.0: stock=10, threshold=10
      final p3 = await repo.create(_input(name: 'AtLimit', lowStockThreshold: 10));
      await _addBatch(db, p3.id, 10, id: 'b-limit');

      final list = await repo.listLowStock();
      final ids = list.map((e) => e.product.id).toList();

      expect(ids.indexOf(p2.id), lessThan(ids.indexOf(p1.id)));
      expect(ids.indexOf(p1.id), lessThan(ids.indexOf(p3.id)));
    });

    test('product with stock=0 appears first (most critical)', () async {
      // ratio 0.0: stock=0, threshold=10
      final zero = await repo.create(_input(name: 'ZeroStock', lowStockThreshold: 10));
      // No batch → stock = 0

      // ratio 0.5: stock=5, threshold=10
      final half = await repo.create(_input(name: 'HalfStock', lowStockThreshold: 10));
      await _addBatch(db, half.id, 5, id: 'b-half2');

      final list = await repo.listLowStock();
      final ids = list.map((e) => e.product.id).toList();

      expect(ids.indexOf(zero.id), lessThan(ids.indexOf(half.id)));
    });

    // -------------------------------------------------------------------------
    // Edge case: threshold == 0 handled gracefully (ratio treated as 0.0)
    // -------------------------------------------------------------------------

    test('product with threshold=0 is included and treated as ratio 0.0',
        () async {
      final p = await repo.create(_input(name: 'ZeroThreshold', lowStockThreshold: 0));
      // stock=0 <= threshold=0 → should appear

      final list = await repo.listLowStock();
      expect(list.any((e) => e.product.id == p.id), isTrue);
    });

    test('empty list returned when no products are low on stock', () async {
      final p = await repo.create(_input(name: 'WellStocked', lowStockThreshold: 5));
      await _addBatch(db, p.id, 100, id: 'b-well');

      final list = await repo.listLowStock();
      expect(list, isEmpty);
    });
  });
}
