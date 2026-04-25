import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_pos/database/database.dart';

/// Opens an in-memory database for testing.
AppDatabase _openTestDb() => AppDatabase.forTesting(NativeDatabase.memory());

void main() {
  group('AppDatabase schema smoke tests', () {
    late AppDatabase db;

    setUp(() {
      db = _openTestDb();
    });

    tearDown(() async {
      await db.close();
    });

    test('database opens and creates all tables without error', () async {
      // If the schema is invalid, this will throw during migration.
      final result = await db.customSelect('SELECT name FROM sqlite_master WHERE type="table"').get();
      final tableNames = result.map((r) => r.read<String>('name')).toSet();

      expect(tableNames, containsAll([
        'users',
        'products',
        'batches',
        'stock_ins',
        'stock_in_lines',
        'stock_adjustments',
        'sales',
        'sale_items',
        'offline_queue',
        'settings',
      ]));
    });

    test('default near_expiry_window_days setting is seeded', () async {
      final row = await (db.select(db.settings)
            ..where((s) => s.key.equals('near_expiry_window_days')))
          .getSingleOrNull();

      expect(row, isNotNull);
      expect(row!.value, equals('90'));
    });

    test('can insert and retrieve a product', () async {
      await db.into(db.products).insert(
            ProductsCompanion.insert(
              id: 'prod-001',
              name: 'Paracetamol 500mg',
              genericName: 'Paracetamol',
              category: 'Analgesic',
              unitOfMeasure: 'Tablet',
              sellingPrice: 500, // ZMW 5.00
              lowStockThreshold: 50,
            ),
          );

      final products = await db.select(db.products).get();
      expect(products.length, equals(1));
      expect(products.first.name, equals('Paracetamol 500mg'));
      expect(products.first.sellingPrice, equals(500));
    });

    test('can insert a user with hashed password', () async {
      await db.into(db.users).insertOnConflictUpdate(
            UsersCompanion.insert(
              id: 'user-001',
              username: 'testuser001',
              passwordHash: r'$2b$12$hashedpassword',
              role: 'admin',
            ),
          );

      final users = await (db.select(db.users)
            ..where((u) => u.id.equals('user-001')))
          .get();
      expect(users.length, equals(1));
      expect(users.first.role, equals('admin'));
      expect(users.first.locked, isFalse);
      expect(users.first.failedAttempts, equals(0));
    });

    test('monetary values are stored as integer cents', () async {
      await db.into(db.products).insert(
            ProductsCompanion.insert(
              id: 'prod-002',
              name: 'Amoxicillin 250mg',
              genericName: 'Amoxicillin',
              category: 'Antibiotic',
              unitOfMeasure: 'Capsule',
              sellingPrice: 1250, // ZMW 12.50
              lowStockThreshold: 20,
            ),
          );

      final product = await (db.select(db.products)
            ..where((p) => p.id.equals('prod-002')))
          .getSingle();

      // Verify integer cents storage
      expect(product.sellingPrice, isA<int>());
      expect(product.sellingPrice, equals(1250));
    });

    test('offline queue defaults synced to false', () async {
      await db.into(db.offlineQueue).insert(
            OfflineQueueCompanion.insert(
              id: 'oq-001',
              entityType: 'sale',
              entityId: 'sale-001',
              operation: 'INSERT',
              payloadJson: '{"id":"sale-001"}',
            ),
          );

      final entry = await (db.select(db.offlineQueue)
            ..where((q) => q.id.equals('oq-001')))
          .getSingle();

      expect(entry.synced, isFalse);
    });
  });
}
