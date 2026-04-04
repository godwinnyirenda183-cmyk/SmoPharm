import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
// Hide Drift-generated Product to avoid conflict with domain entity.
import 'package:pharmacy_pos/database/database.dart' hide Product;
import 'package:pharmacy_pos/data/repositories/product_repository_impl.dart';
import 'package:pharmacy_pos/domain/entities/product.dart';

AppDatabase _openTestDb() => AppDatabase.forTesting(NativeDatabase.memory());

/// Helper to build a minimal [ProductInput].
ProductInput _input({
  String name = 'Paracetamol',
  String genericName = 'Acetaminophen',
  String category = 'Analgesic',
  String unitOfMeasure = 'Tablet',
  int sellingPrice = 500,
  int lowStockThreshold = 10,
}) =>
    ProductInput(
      name: name,
      genericName: genericName,
      category: category,
      unitOfMeasure: unitOfMeasure,
      sellingPrice: sellingPrice,
      lowStockThreshold: lowStockThreshold,
    );

void main() {
  group('ProductRepositoryImpl', () {
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
    // create
    // -------------------------------------------------------------------------

    test('create assigns a non-empty UUID to the product', () async {
      final product = await repo.create(_input());
      expect(product.id, isNotEmpty);
      // UUID v4 format: 8-4-4-4-12 hex chars
      final uuidPattern = RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          caseSensitive: false);
      expect(uuidPattern.hasMatch(product.id), isTrue);
    });

    test('create persists product fields correctly', () async {
      final product = await repo.create(_input(
        name: 'Amoxicillin',
        genericName: 'Amoxicillin trihydrate',
        category: 'Antibiotic',
        unitOfMeasure: 'Capsule',
        sellingPrice: 1200,
        lowStockThreshold: 20,
      ));

      expect(product.name, equals('Amoxicillin'));
      expect(product.genericName, equals('Amoxicillin trihydrate'));
      expect(product.category, equals('Antibiotic'));
      expect(product.unitOfMeasure, equals('Capsule'));
      expect(product.sellingPrice, equals(1200));
      expect(product.lowStockThreshold, equals(20));
    });

    test('create assigns distinct UUIDs to different products', () async {
      final p1 = await repo.create(_input(name: 'Product A'));
      final p2 = await repo.create(_input(name: 'Product B'));
      expect(p1.id, isNot(equals(p2.id)));
    });

    // -------------------------------------------------------------------------
    // update
    // -------------------------------------------------------------------------

    test('update changes product fields and returns updated entity', () async {
      final created = await repo.create(_input());

      final updated = await repo.update(
        created.id,
        _input(
          name: 'Ibuprofen',
          genericName: 'Ibuprofen',
          category: 'NSAID',
          unitOfMeasure: 'Tablet',
          sellingPrice: 800,
          lowStockThreshold: 15,
        ),
      );

      expect(updated.id, equals(created.id));
      expect(updated.name, equals('Ibuprofen'));
      expect(updated.genericName, equals('Ibuprofen'));
      expect(updated.category, equals('NSAID'));
      expect(updated.sellingPrice, equals(800));
      expect(updated.lowStockThreshold, equals(15));
    });

    test('update sets updatedAt timestamp', () async {
      final created = await repo.create(_input());
      final updated = await repo.update(created.id, _input(name: 'Updated'));
      // updatedAt should be a valid DateTime (not null/epoch).
      expect(updated.updatedAt.year, greaterThanOrEqualTo(2024));
    });

    // -------------------------------------------------------------------------
    // delete — success
    // -------------------------------------------------------------------------

    test('delete removes a product with no associations', () async {
      final product = await repo.create(_input());
      await repo.delete(product.id);

      final all = await repo.listAll();
      expect(all.any((p) => p.product.id == product.id), isFalse);
    });

    // -------------------------------------------------------------------------
    // delete — referential integrity: batch
    // -------------------------------------------------------------------------

    test('delete throws StateError when product has an associated batch',
        () async {
      final product = await repo.create(_input());

      // Insert a batch linked to this product.
      await db.into(db.batches).insert(BatchesCompanion.insert(
            id: 'batch-1',
            productId: product.id,
            batchNumber: 'LOT001',
            expiryDate: DateTime(2026, 12, 31),
            supplierName: 'Supplier A',
            quantityReceived: 100,
            quantityRemaining: 100,
            costPricePerUnit: 200,
          ));

      expect(
        () => repo.delete(product.id),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          'Cannot delete product with existing batches or sales',
        )),
      );
    });

    // -------------------------------------------------------------------------
    // delete — referential integrity: sale item
    // -------------------------------------------------------------------------

    test('delete throws StateError when product has an associated sale item',
        () async {
      final product = await repo.create(_input());

      // Need a user, sale, and batch before inserting a sale item.
      await db.into(db.users).insert(UsersCompanion.insert(
            id: 'user-1',
            username: 'cashier1',
            passwordHash: 'hash',
            role: 'cashier',
          ));

      await db.into(db.batches).insert(BatchesCompanion.insert(
            id: 'batch-si',
            productId: product.id,
            batchNumber: 'LOT002',
            expiryDate: DateTime(2026, 12, 31),
            supplierName: 'Supplier B',
            quantityReceived: 50,
            quantityRemaining: 50,
            costPricePerUnit: 150,
          ));

      await db.into(db.sales).insert(SalesCompanion.insert(
            id: 'sale-1',
            userId: 'user-1',
            totalZmw: 500,
            paymentMethod: 'Cash',
          ));

      await db.into(db.saleItems).insert(SaleItemsCompanion.insert(
            id: 'si-1',
            saleId: 'sale-1',
            productId: product.id,
            batchId: 'batch-si',
            quantity: 1,
            unitPrice: 500,
            lineTotal: 500,
          ));

      // Remove the batch so only the sale item triggers the guard.
      await (db.delete(db.batches)
            ..where((b) => b.id.equals('batch-si')))
          .go();

      expect(
        () => repo.delete(product.id),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          'Cannot delete product with existing batches or sales',
        )),
      );
    });

    // -------------------------------------------------------------------------
    // search
    // -------------------------------------------------------------------------

    test('search by name is case-insensitive', () async {
      await repo.create(_input(name: 'Paracetamol', genericName: 'Acetaminophen'));

      final results = await repo.search('PARACETAMOL');
      expect(results, hasLength(1));
      expect(results.first.name, equals('Paracetamol'));
    });

    test('search by generic name is case-insensitive', () async {
      await repo.create(_input(name: 'Tylenol', genericName: 'Acetaminophen'));

      final results = await repo.search('acetaminophen');
      expect(results, hasLength(1));
      expect(results.first.genericName, equals('Acetaminophen'));
    });

    test('search returns partial matches', () async {
      await repo.create(_input(name: 'Amoxicillin 500mg'));
      await repo.create(_input(name: 'Amoxicillin 250mg'));
      await repo.create(_input(name: 'Ibuprofen'));

      final results = await repo.search('amoxicillin');
      expect(results, hasLength(2));
    });

    test('search returns empty list when no match', () async {
      await repo.create(_input(name: 'Paracetamol'));

      final results = await repo.search('Zyrtec');
      expect(results, isEmpty);
    });

    test('search matches against both name and generic name', () async {
      await repo.create(_input(name: 'Tylenol', genericName: 'Acetaminophen'));
      await repo.create(_input(name: 'Paracetamol', genericName: 'Paracetamol'));

      // 'para' matches Paracetamol by name and Paracetamol by generic name.
      final results = await repo.search('para');
      expect(results.any((p) => p.name == 'Paracetamol'), isTrue);
    });

    // -------------------------------------------------------------------------
    // listAll — stock level
    // -------------------------------------------------------------------------

    test('listAll returns stock level as sum of non-expired batch quantities',
        () async {
      final product = await repo.create(_input());

      // Two active batches.
      await db.into(db.batches).insert(BatchesCompanion.insert(
            id: 'b1',
            productId: product.id,
            batchNumber: 'LOT-A',
            expiryDate: DateTime(2027, 1, 1),
            supplierName: 'S1',
            quantityReceived: 60,
            quantityRemaining: 60,
            costPricePerUnit: 100,
            status: const Value('active'),
          ));

      await db.into(db.batches).insert(BatchesCompanion.insert(
            id: 'b2',
            productId: product.id,
            batchNumber: 'LOT-B',
            expiryDate: DateTime(2027, 6, 1),
            supplierName: 'S1',
            quantityReceived: 40,
            quantityRemaining: 40,
            costPricePerUnit: 100,
            status: const Value('active'),
          ));

      // One expired batch — should NOT be counted.
      await db.into(db.batches).insert(BatchesCompanion.insert(
            id: 'b3',
            productId: product.id,
            batchNumber: 'LOT-C',
            expiryDate: DateTime(2020, 1, 1),
            supplierName: 'S1',
            quantityReceived: 20,
            quantityRemaining: 20,
            costPricePerUnit: 100,
            status: const Value('expired'),
          ));

      final all = await repo.listAll();
      final entry = all.firstWhere((p) => p.product.id == product.id);

      // 60 + 40 = 100 (expired batch of 20 excluded)
      expect(entry.stockLevel, equals(100));
    });

    test('listAll returns zero stock level when product has no batches',
        () async {
      final product = await repo.create(_input());

      final all = await repo.listAll();
      final entry = all.firstWhere((p) => p.product.id == product.id);
      expect(entry.stockLevel, equals(0));
    });

    test('listAll excludes expired batches from stock level', () async {
      final product = await repo.create(_input());

      await db.into(db.batches).insert(BatchesCompanion.insert(
            id: 'b-exp',
            productId: product.id,
            batchNumber: 'LOT-EXP',
            expiryDate: DateTime(2019, 1, 1),
            supplierName: 'S1',
            quantityReceived: 100,
            quantityRemaining: 100,
            costPricePerUnit: 100,
            status: const Value('expired'),
          ));

      final all = await repo.listAll();
      final entry = all.firstWhere((p) => p.product.id == product.id);
      expect(entry.stockLevel, equals(0));
    });
  });
}
