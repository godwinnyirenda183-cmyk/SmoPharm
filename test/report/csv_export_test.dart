// Feature: pharmacy-pos, Property 17: CSV Export Completeness
// Validates: Requirements 7.5

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_pos/domain/entities/batch.dart';
import 'package:pharmacy_pos/domain/entities/product.dart';
import 'package:pharmacy_pos/domain/entities/sale.dart';
import 'package:pharmacy_pos/domain/services/report_service.dart';
import 'package:drift/native.dart';
import 'package:pharmacy_pos/database/database.dart' as db_lib;
import 'package:pharmacy_pos/data/repositories/product_repository_impl.dart';
import 'package:pharmacy_pos/data/services/report_service_impl.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

db_lib.AppDatabase _openTestDb() =>
    db_lib.AppDatabase.forTesting(NativeDatabase.memory());

Product _makeProduct({
  String id = 'prod-1',
  String name = 'Paracetamol',
  String genericName = 'Acetaminophen',
  String category = 'Analgesic',
  String unitOfMeasure = 'Tablet',
}) =>
    Product(
      id: id,
      name: name,
      genericName: genericName,
      category: category,
      unitOfMeasure: unitOfMeasure,
      sellingPrice: 500,
      lowStockThreshold: 10,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );

Batch _makeBatch({
  String id = 'batch-1',
  String productId = 'prod-1',
  String batchNumber = 'BN001',
  DateTime? expiryDate,
  int quantityRemaining = 50,
}) =>
    Batch(
      id: id,
      productId: productId,
      batchNumber: batchNumber,
      expiryDate: expiryDate ?? DateTime(2025, 6, 30),
      supplierName: 'Supplier A',
      quantityReceived: 100,
      quantityRemaining: quantityRemaining,
      costPricePerUnit: 200,
      receivedDate: DateTime(2024, 1, 1),
      status: BatchStatus.active,
    );

/// Splits a CSV string into rows, then each row into fields.
/// Handles quoted fields with embedded commas.
List<List<String>> _parseCsv(String csv) {
  return csv
      .trim()
      .split('\n')
      .map((line) => line.split(',').map((f) => f.trim()).toList())
      .toList();
}

void main() {
  late db_lib.AppDatabase db;
  late ReportServiceImpl service;

  setUp(() {
    db = _openTestDb();
    final productRepo = ProductRepositoryImpl(db);
    service = ReportServiceImpl(db, productRepo);
  });

  tearDown(() async {
    await db.close();
  });

  // ---------------------------------------------------------------------------
  // Daily Sales Report CSV
  // ---------------------------------------------------------------------------

  group('exportCsv — DailySalesReport', () {
    test('has correct headers', () async {
      final csv = await service.exportCsv<DailySalesReport>([]);
      final rows = _parseCsv(csv);

      expect(rows.length, equals(1)); // header only
      expect(rows[0][0], equals('Date'));
      expect(rows[0][1], equals('Total Revenue (ZMW)'));
      expect(rows[0][2], equals('Transaction Count'));
      expect(rows[0][3], equals('Cash Revenue (ZMW)'));
      expect(rows[0][4], equals('Mobile Money Revenue (ZMW)'));
      expect(rows[0][5], equals('Insurance Revenue (ZMW)'));
    });

    test('has correct data row for a report with all payment methods',
        () async {
      final report = DailySalesReport(
        totalRevenueCents: 7300,
        transactionCount: 4,
        revenueByPaymentMethod: {
          PaymentMethod.cash: 3500,
          PaymentMethod.mobileMoney: 3000,
          PaymentMethod.insurance: 800,
        },
      );

      final csv = await service.exportCsv<DailySalesReport>([report]);
      final rows = _parseCsv(csv);

      expect(rows.length, equals(2)); // header + 1 data row
      final data = rows[1];
      expect(data[1], equals('73.00')); // total revenue
      expect(data[2], equals('4'));     // transaction count
      expect(data[3], equals('35.00')); // cash
      expect(data[4], equals('30.00')); // mobile money
      expect(data[5], equals('8.00'));  // insurance
    });

    test('missing payment methods default to 0.00', () async {
      final report = DailySalesReport(
        totalRevenueCents: 1000,
        transactionCount: 1,
        revenueByPaymentMethod: {
          PaymentMethod.cash: 1000,
        },
      );

      final csv = await service.exportCsv<DailySalesReport>([report]);
      final rows = _parseCsv(csv);
      final data = rows[1];

      expect(data[4], equals('0.00')); // mobile money
      expect(data[5], equals('0.00')); // insurance
    });

    test('empty list produces only headers', () async {
      final csv = await service.exportCsv<DailySalesReport>([]);
      final rows = _parseCsv(csv);
      expect(rows.length, equals(1));
    });
  });

  // ---------------------------------------------------------------------------
  // Inventory Report CSV
  // ---------------------------------------------------------------------------

  group('exportCsv — InventoryReportRow', () {
    test('has correct headers', () async {
      final csv = await service.exportCsv<InventoryReportRow>([]);
      final rows = _parseCsv(csv);

      expect(rows.length, equals(1));
      expect(rows[0][0], equals('Product Name'));
      expect(rows[0][1], equals('Generic Name'));
      expect(rows[0][2], equals('Category'));
      expect(rows[0][3], equals('Unit of Measure'));
      expect(rows[0][4], equals('Stock Level'));
      expect(rows[0][5], equals('Unit Cost (ZMW)'));
      expect(rows[0][6], equals('Total Value (ZMW)'));
    });

    test('has correct data row', () async {
      final row = InventoryReportRow(
        product: _makeProduct(),
        stockLevel: 42,
        unitCostCents: 250,
        totalValueCents: 10500,
      );

      final csv = await service.exportCsv<InventoryReportRow>([row]);
      final rows = _parseCsv(csv);

      expect(rows.length, equals(2));
      final data = rows[1];
      expect(data[0], equals('Paracetamol'));
      expect(data[1], equals('Acetaminophen'));
      expect(data[2], equals('Analgesic'));
      expect(data[3], equals('Tablet'));
      expect(data[4], equals('42'));
      expect(data[5], equals('2.50'));
      expect(data[6], equals('105.00'));
    });

    test('multiple rows are all present', () async {
      final rows = [
        InventoryReportRow(
          product: _makeProduct(id: 'p1', name: 'Drug A'),
          stockLevel: 10,
          unitCostCents: 100,
          totalValueCents: 1000,
        ),
        InventoryReportRow(
          product: _makeProduct(id: 'p2', name: 'Drug B'),
          stockLevel: 20,
          unitCostCents: 200,
          totalValueCents: 4000,
        ),
      ];

      final csv = await service.exportCsv<InventoryReportRow>(rows);
      final parsed = _parseCsv(csv);

      expect(parsed.length, equals(3)); // header + 2 rows
      expect(parsed[1][0], equals('Drug A'));
      expect(parsed[2][0], equals('Drug B'));
    });

    test('empty list produces only headers', () async {
      final csv = await service.exportCsv<InventoryReportRow>([]);
      final rows = _parseCsv(csv);
      expect(rows.length, equals(1));
    });
  });

  // ---------------------------------------------------------------------------
  // Low-Stock Report CSV
  // ---------------------------------------------------------------------------

  group('exportCsv — LowStockReportRow', () {
    test('has correct headers', () async {
      final csv = await service.exportCsv<LowStockReportRow>([]);
      final rows = _parseCsv(csv);

      expect(rows.length, equals(1));
      expect(rows[0][0], equals('Product Name'));
      expect(rows[0][1], equals('Generic Name'));
      expect(rows[0][2], equals('Stock Level'));
      expect(rows[0][3], equals('Low Stock Threshold'));
    });

    test('has correct data row', () async {
      final row = LowStockReportRow(
        product: _makeProduct(name: 'Amoxicillin', genericName: 'Amoxicillin'),
        stockLevel: 3,
        lowStockThreshold: 15,
      );

      final csv = await service.exportCsv<LowStockReportRow>([row]);
      final rows = _parseCsv(csv);

      expect(rows.length, equals(2));
      final data = rows[1];
      expect(data[0], equals('Amoxicillin'));
      expect(data[1], equals('Amoxicillin'));
      expect(data[2], equals('3'));
      expect(data[3], equals('15'));
    });

    test('empty list produces only headers', () async {
      final csv = await service.exportCsv<LowStockReportRow>([]);
      final rows = _parseCsv(csv);
      expect(rows.length, equals(1));
    });
  });

  // ---------------------------------------------------------------------------
  // Near-Expiry Report CSV
  // ---------------------------------------------------------------------------

  group('exportCsv — NearExpiryReportRow', () {
    test('has correct headers', () async {
      final csv = await service.exportCsv<NearExpiryReportRow>([]);
      final rows = _parseCsv(csv);

      expect(rows.length, equals(1));
      expect(rows[0][0], equals('Product Name'));
      expect(rows[0][1], equals('Batch Number'));
      expect(rows[0][2], equals('Expiry Date'));
      expect(rows[0][3], equals('Quantity Remaining'));
    });

    test('has correct data row', () async {
      final product = _makeProduct(name: 'Metformin');
      final batch = _makeBatch(
        batchNumber: 'BN-2025-001',
        expiryDate: DateTime(2025, 3, 15),
        quantityRemaining: 12,
      );

      final row = NearExpiryReportRow(product: product, batch: batch);
      final csv = await service.exportCsv<NearExpiryReportRow>([row]);
      final rows = _parseCsv(csv);

      expect(rows.length, equals(2));
      final data = rows[1];
      expect(data[0], equals('Metformin'));
      expect(data[1], equals('BN-2025-001'));
      expect(data[2], equals('2025-03-15'));
      expect(data[3], equals('12'));
    });

    test('empty list produces only headers', () async {
      final csv = await service.exportCsv<NearExpiryReportRow>([]);
      final rows = _parseCsv(csv);
      expect(rows.length, equals(1));
    });
  });
}
