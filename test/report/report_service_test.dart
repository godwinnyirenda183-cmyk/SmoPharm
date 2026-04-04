import 'package:drift/drift.dart' hide Batch;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_pos/data/repositories/product_repository_impl.dart';
import 'package:pharmacy_pos/data/services/report_service_impl.dart';
import 'package:pharmacy_pos/database/database.dart' as db_lib;
import 'package:pharmacy_pos/domain/entities/sale.dart';

db_lib.AppDatabase _openTestDb() =>
    db_lib.AppDatabase.forTesting(NativeDatabase.memory());

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

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

Future<String> _insertProduct(
  db_lib.AppDatabase db, {
  String id = 'prod-1',
  String name = 'Paracetamol',
  int sellingPrice = 500,
  int lowStockThreshold = 10,
}) async {
  await db.into(db.products).insert(db_lib.ProductsCompanion.insert(
        id: id,
        name: name,
        genericName: 'Generic $name',
        category: 'General',
        unitOfMeasure: 'Tablet',
        sellingPrice: sellingPrice,
        lowStockThreshold: lowStockThreshold,
      ));
  return id;
}

Future<String> _insertBatch(
  db_lib.AppDatabase db, {
  required String productId,
  required int quantity,
  String? id,
  int costPricePerUnit = 200,
  String status = 'active',
  DateTime? expiryDate,
  DateTime? receivedDate,
}) async {
  final batchId = id ?? 'batch-${DateTime.now().microsecondsSinceEpoch}';
  await db.into(db.batches).insert(db_lib.BatchesCompanion.insert(
        id: batchId,
        productId: productId,
        batchNumber: batchId,
        expiryDate: expiryDate ?? DateTime.now().add(const Duration(days: 365)),
        supplierName: 'Supplier',
        quantityReceived: quantity,
        quantityRemaining: quantity,
        costPricePerUnit: costPricePerUnit,
        receivedDate: Value(receivedDate ?? DateTime.now()),
        status: Value(status),
      ));
  return batchId;
}

/// Insert a sale directly (bypassing SaleRepository to control voided flag).
Future<String> _insertSale(
  db_lib.AppDatabase db, {
  required String userId,
  required DateTime recordedAt,
  required int totalZmw,
  required String paymentMethod,
  bool voided = false,
  String? id,
}) async {
  final saleId = id ?? 'sale-${DateTime.now().microsecondsSinceEpoch}';
  await db.into(db.sales).insert(db_lib.SalesCompanion.insert(
        id: saleId,
        userId: userId,
        recordedAt: Value(recordedAt),
        totalZmw: totalZmw,
        paymentMethod: paymentMethod,
        voided: Value(voided),
      ));
  return saleId;
}

void main() {
  group('ReportServiceImpl', () {
    late db_lib.AppDatabase db;
    late ProductRepositoryImpl productRepo;
    late ReportServiceImpl service;

    setUp(() {
      db = _openTestDb();
      productRepo = ProductRepositoryImpl(db);
      service = ReportServiceImpl(db, productRepo);
    });

    tearDown(() async {
      await db.close();
    });

    // -------------------------------------------------------------------------
    // Daily Sales Report — excludes voided sales
    // -------------------------------------------------------------------------

    test('dailySalesReport excludes voided sales from revenue', () async {
      final userId = await _insertUser(db);
      final today = DateTime.now();
      final dayStart = DateTime(today.year, today.month, today.day, 10);

      // Non-voided sale: 1000 cents
      await _insertSale(db,
          userId: userId,
          recordedAt: dayStart,
          totalZmw: 1000,
          paymentMethod: 'Cash',
          voided: false,
          id: 'sale-valid');

      // Voided sale: 500 cents — must be excluded
      await _insertSale(db,
          userId: userId,
          recordedAt: dayStart.add(const Duration(hours: 1)),
          totalZmw: 500,
          paymentMethod: 'Cash',
          voided: true,
          id: 'sale-voided');

      final report = await service.dailySalesReport(today);

      expect(report.totalRevenueCents, equals(1000));
      expect(report.transactionCount, equals(1));
    });

    // -------------------------------------------------------------------------
    // Daily Sales Report — aggregates by payment method
    // -------------------------------------------------------------------------

    test('dailySalesReport aggregates revenue by payment method', () async {
      final userId = await _insertUser(db);
      final today = DateTime.now();
      final dayStart = DateTime(today.year, today.month, today.day, 9);

      await _insertSale(db,
          userId: userId,
          recordedAt: dayStart,
          totalZmw: 2000,
          paymentMethod: 'Cash',
          id: 'sale-cash-1');

      await _insertSale(db,
          userId: userId,
          recordedAt: dayStart.add(const Duration(hours: 1)),
          totalZmw: 1500,
          paymentMethod: 'Cash',
          id: 'sale-cash-2');

      await _insertSale(db,
          userId: userId,
          recordedAt: dayStart.add(const Duration(hours: 2)),
          totalZmw: 3000,
          paymentMethod: 'Mobile_Money',
          id: 'sale-mm');

      await _insertSale(db,
          userId: userId,
          recordedAt: dayStart.add(const Duration(hours: 3)),
          totalZmw: 800,
          paymentMethod: 'Insurance',
          id: 'sale-ins');

      final report = await service.dailySalesReport(today);

      expect(report.totalRevenueCents, equals(7300));
      expect(report.transactionCount, equals(4));
      expect(report.revenueByPaymentMethod[PaymentMethod.cash], equals(3500));
      expect(
          report.revenueByPaymentMethod[PaymentMethod.mobileMoney], equals(3000));
      expect(
          report.revenueByPaymentMethod[PaymentMethod.insurance], equals(800));
    });

    // -------------------------------------------------------------------------
    // Daily Sales Report — returns 0 for a day with no sales
    // -------------------------------------------------------------------------

    test('dailySalesReport returns zeros for a day with no sales', () async {
      // Use a date far in the past with no sales.
      final emptyDay = DateTime(2000, 1, 1);

      final report = await service.dailySalesReport(emptyDay);

      expect(report.totalRevenueCents, equals(0));
      expect(report.transactionCount, equals(0));
      expect(report.revenueByPaymentMethod, isEmpty);
    });

    // -------------------------------------------------------------------------
    // Daily Sales Report — only includes sales from the requested day
    // -------------------------------------------------------------------------

    test('dailySalesReport only includes sales from the requested day',
        () async {
      final userId = await _insertUser(db);
      final targetDay = DateTime(2024, 6, 15);
      final otherDay = DateTime(2024, 6, 16);

      await _insertSale(db,
          userId: userId,
          recordedAt: DateTime(2024, 6, 15, 10),
          totalZmw: 1000,
          paymentMethod: 'Cash',
          id: 'sale-target');

      await _insertSale(db,
          userId: userId,
          recordedAt: DateTime(2024, 6, 16, 10),
          totalZmw: 9999,
          paymentMethod: 'Cash',
          id: 'sale-other');

      final report = await service.dailySalesReport(targetDay);
      expect(report.totalRevenueCents, equals(1000));
      expect(report.transactionCount, equals(1));

      final otherReport = await service.dailySalesReport(otherDay);
      expect(otherReport.totalRevenueCents, equals(9999));
    });

    // -------------------------------------------------------------------------
    // Inventory Report — includes stock value
    // -------------------------------------------------------------------------

    test('inventoryReport includes correct total stock value', () async {
      final productId = await _insertProduct(db, id: 'prod-inv');

      // Batch 1: 10 units @ 300 cents = 3000
      await _insertBatch(db,
          productId: productId,
          quantity: 10,
          costPricePerUnit: 300,
          id: 'batch-inv-1');

      // Batch 2: 5 units @ 400 cents = 2000
      await _insertBatch(db,
          productId: productId,
          quantity: 5,
          costPricePerUnit: 400,
          id: 'batch-inv-2');

      final rows = await service.inventoryReport();
      final row = rows.firstWhere((r) => r.product.id == productId);

      expect(row.stockLevel, equals(15));
      // Total value = 10*300 + 5*400 = 3000 + 2000 = 5000
      expect(row.totalValueCents, equals(5000));
    });

    test('inventoryReport excludes expired batches from stock level and value',
        () async {
      final productId = await _insertProduct(db, id: 'prod-exp');

      // Active batch: 20 units @ 200 cents
      await _insertBatch(db,
          productId: productId,
          quantity: 20,
          costPricePerUnit: 200,
          status: 'active',
          id: 'batch-active');

      // Expired batch: 50 units @ 100 cents — must be excluded
      await _insertBatch(db,
          productId: productId,
          quantity: 50,
          costPricePerUnit: 100,
          status: 'expired',
          id: 'batch-expired');

      final rows = await service.inventoryReport();
      final row = rows.firstWhere((r) => r.product.id == productId);

      expect(row.stockLevel, equals(20));
      expect(row.totalValueCents, equals(4000)); // 20 * 200
    });

    // -------------------------------------------------------------------------
    // Low-Stock Report — returns correct products
    // -------------------------------------------------------------------------

    test('lowStockReport returns products at or below threshold', () async {
      // Product A: stock 5, threshold 10 → low stock
      final prodA = await _insertProduct(db,
          id: 'prod-low-a',
          name: 'LowDrug A',
          lowStockThreshold: 10);
      await _insertBatch(db, productId: prodA, quantity: 5, id: 'b-low-a');

      // Product B: stock 20, threshold 10 → NOT low stock
      final prodB = await _insertProduct(db,
          id: 'prod-ok-b',
          name: 'OkDrug B',
          lowStockThreshold: 10);
      await _insertBatch(db, productId: prodB, quantity: 20, id: 'b-ok-b');

      // Product C: stock exactly at threshold (10) → low stock
      final prodC = await _insertProduct(db,
          id: 'prod-low-c',
          name: 'LowDrug C',
          lowStockThreshold: 10);
      await _insertBatch(db, productId: prodC, quantity: 10, id: 'b-low-c');

      final rows = await service.lowStockReport();
      final ids = rows.map((r) => r.product.id).toSet();

      expect(ids, contains(prodA));
      expect(ids, contains(prodC));
      expect(ids, isNot(contains(prodB)));
    });

    test('lowStockReport is sorted by criticality (ratio ascending)', () async {
      // Product A: stock 1, threshold 10 → ratio 0.1 (most critical)
      final prodA = await _insertProduct(db,
          id: 'prod-sort-a',
          name: 'SortDrug A',
          lowStockThreshold: 10);
      await _insertBatch(db, productId: prodA, quantity: 1, id: 'b-sort-a');

      // Product B: stock 5, threshold 10 → ratio 0.5
      final prodB = await _insertProduct(db,
          id: 'prod-sort-b',
          name: 'SortDrug B',
          lowStockThreshold: 10);
      await _insertBatch(db, productId: prodB, quantity: 5, id: 'b-sort-b');

      final rows = await service.lowStockReport();
      final sortedIds = rows.map((r) => r.product.id).toList();

      final idxA = sortedIds.indexOf(prodA);
      final idxB = sortedIds.indexOf(prodB);

      expect(idxA, lessThan(idxB));
    });

    // -------------------------------------------------------------------------
    // Near-Expiry Report — returns correct batches
    // -------------------------------------------------------------------------

    test('nearExpiryReport returns batches with near_expiry status', () async {
      final productId = await _insertProduct(db, id: 'prod-ne');

      // Near-expiry batch
      await _insertBatch(db,
          productId: productId,
          quantity: 10,
          status: 'near_expiry',
          expiryDate: DateTime.now().add(const Duration(days: 30)),
          id: 'batch-ne');

      // Active batch — should NOT appear
      await _insertBatch(db,
          productId: productId,
          quantity: 20,
          status: 'active',
          expiryDate: DateTime.now().add(const Duration(days: 200)),
          id: 'batch-active-ne');

      final rows = await service.nearExpiryReport();
      final batchIds = rows.map((r) => r.batch.id).toSet();

      expect(batchIds, contains('batch-ne'));
      expect(batchIds, isNot(contains('batch-active-ne')));
    });

    test('nearExpiryReport includes product name and batch details', () async {
      final productId =
          await _insertProduct(db, id: 'prod-ne2', name: 'Amoxicillin');

      final expiry = DateTime.now().add(const Duration(days: 45));
      await _insertBatch(db,
          productId: productId,
          quantity: 8,
          status: 'near_expiry',
          expiryDate: expiry,
          id: 'batch-ne2');

      final rows = await service.nearExpiryReport();
      final row = rows.firstWhere((r) => r.batch.id == 'batch-ne2');

      expect(row.product.name, equals('Amoxicillin'));
      expect(row.batch.batchNumber, equals('batch-ne2'));
      expect(row.batch.quantityRemaining, equals(8));
      expect(row.batch.expiryDate.day, equals(expiry.day));
    });

    test('nearExpiryReport does not include expired batches', () async {
      final productId = await _insertProduct(db, id: 'prod-ne3');

      await _insertBatch(db,
          productId: productId,
          quantity: 5,
          status: 'expired',
          expiryDate: DateTime.now().subtract(const Duration(days: 10)),
          id: 'batch-expired-ne');

      final rows = await service.nearExpiryReport();
      final batchIds = rows.map((r) => r.batch.id).toSet();

      expect(batchIds, isNot(contains('batch-expired-ne')));
    });
  });
}
