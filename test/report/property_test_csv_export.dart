// Feature: pharmacy-pos, Property 17: CSV Export Completeness
//
// Validates: Requirements 7.5
//
// Property 17: For any report, the exported CSV SHALL contain the same set of
// rows and columns as the on-screen report, with no data omitted or added.
//
// Specifically tested here:
//   For any N report rows, the exported CSV has exactly N+1 lines
//   (1 header row + N data rows), for each of the four report types:
//   InventoryReportRow, LowStockReportRow, NearExpiryReportRow,
//   and DailySalesReport.

import 'package:glados/glados.dart';
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

/// Counts the number of non-empty lines in a CSV string.
/// The csv package separates rows with '\r\n' or '\n'.
int _csvLineCount(String csv) {
  final trimmed = csv.trim();
  if (trimmed.isEmpty) return 0;
  // Split on both \r\n and \n.
  return trimmed.split(RegExp(r'\r?\n')).length;
}

/// Builds a synthetic [Product] from an integer seed.
Product _makeProduct(int seed) => Product(
      id: 'prod-p17-$seed',
      name: 'Product $seed',
      genericName: 'Generic $seed',
      category: 'Category ${seed % 5}',
      unitOfMeasure: 'Tablet',
      sellingPrice: 100 + seed,
      lowStockThreshold: 5 + seed % 10,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );

/// Builds a synthetic [Batch] from an integer seed.
Batch _makeBatch(int seed) => Batch(
      id: 'batch-p17-$seed',
      productId: 'prod-p17-$seed',
      batchNumber: 'BN-P17-$seed',
      expiryDate: DateTime(2026, 1 + seed % 12, 1 + seed % 28),
      supplierName: 'Supplier $seed',
      quantityReceived: 50 + seed,
      quantityRemaining: 10 + seed % 40,
      costPricePerUnit: 200 + seed,
      receivedDate: DateTime(2024, 1, 1),
      status: BatchStatus.active,
    );

/// Builds a synthetic [InventoryReportRow] from an integer seed.
InventoryReportRow _makeInventoryRow(int seed) => InventoryReportRow(
      product: _makeProduct(seed),
      stockLevel: 10 + seed,
      unitCostCents: 200 + seed,
      totalValueCents: (10 + seed) * (200 + seed),
    );

/// Builds a synthetic [LowStockReportRow] from an integer seed.
LowStockReportRow _makeLowStockRow(int seed) => LowStockReportRow(
      product: _makeProduct(seed),
      stockLevel: seed % 5,
      lowStockThreshold: 10 + seed % 5,
    );

/// Builds a synthetic [NearExpiryReportRow] from an integer seed.
NearExpiryReportRow _makeNearExpiryRow(int seed) => NearExpiryReportRow(
      product: _makeProduct(seed),
      batch: _makeBatch(seed),
    );

/// Builds a synthetic [DailySalesReport] from an integer seed.
DailySalesReport _makeDailySalesRow(int seed) => DailySalesReport(
      totalRevenueCents: 1000 + seed * 100,
      transactionCount: 1 + seed % 10,
      revenueByPaymentMethod: {
        PaymentMethod.cash: 500 + seed * 50,
        PaymentMethod.mobileMoney: 300 + seed * 30,
        PaymentMethod.insurance: 200 + seed * 20,
      },
    );

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

/// Minimum 100 iterations as required by the testing strategy.
final _exploreConfig = ExploreConfig(numRuns: 100);

/// Generates N in [0, 10] — the number of report rows.
final _genN = any.intInRange(0, 11);

// ---------------------------------------------------------------------------
// Property tests
// ---------------------------------------------------------------------------

void main() {
  group('Property 17: CSV Export Completeness', () {
    // -------------------------------------------------------------------------
    // Property A: Inventory report CSV has exactly N+1 lines for N rows.
    //
    // Strategy:
    //   1. Generate N in [0, 10].
    //   2. Build N synthetic InventoryReportRow objects.
    //   3. Call exportCsv<InventoryReportRow>().
    //   4. Assert the CSV has exactly N+1 lines (1 header + N data rows).
    // -------------------------------------------------------------------------
    Glados(_genN, _exploreConfig).test(
      'inventory report CSV has exactly N+1 lines for N rows',
      (n) async {
        final db = _openTestDb();
        try {
          final productRepo = ProductRepositoryImpl(db);
          final service = ReportServiceImpl(db, productRepo);

          final rows = List.generate(n, _makeInventoryRow);
          final csv = await service.exportCsv<InventoryReportRow>(rows);
          final lineCount = _csvLineCount(csv);

          expect(
            lineCount,
            equals(n + 1),
            reason:
                'Inventory CSV with N=$n rows should have ${n + 1} lines '
                '(1 header + $n data rows) but got $lineCount lines.',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Property B: Low-stock report CSV has exactly N+1 lines for N rows.
    //
    // Strategy:
    //   1. Generate N in [0, 10].
    //   2. Build N synthetic LowStockReportRow objects.
    //   3. Call exportCsv<LowStockReportRow>().
    //   4. Assert the CSV has exactly N+1 lines.
    // -------------------------------------------------------------------------
    Glados(_genN, _exploreConfig).test(
      'low-stock report CSV has exactly N+1 lines for N rows',
      (n) async {
        final db = _openTestDb();
        try {
          final productRepo = ProductRepositoryImpl(db);
          final service = ReportServiceImpl(db, productRepo);

          final rows = List.generate(n, _makeLowStockRow);
          final csv = await service.exportCsv<LowStockReportRow>(rows);
          final lineCount = _csvLineCount(csv);

          expect(
            lineCount,
            equals(n + 1),
            reason:
                'Low-stock CSV with N=$n rows should have ${n + 1} lines '
                '(1 header + $n data rows) but got $lineCount lines.',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Property C: Near-expiry report CSV has exactly N+1 lines for N rows.
    //
    // Strategy:
    //   1. Generate N in [0, 10].
    //   2. Build N synthetic NearExpiryReportRow objects.
    //   3. Call exportCsv<NearExpiryReportRow>().
    //   4. Assert the CSV has exactly N+1 lines.
    // -------------------------------------------------------------------------
    Glados(_genN, _exploreConfig).test(
      'near-expiry report CSV has exactly N+1 lines for N rows',
      (n) async {
        final db = _openTestDb();
        try {
          final productRepo = ProductRepositoryImpl(db);
          final service = ReportServiceImpl(db, productRepo);

          final rows = List.generate(n, _makeNearExpiryRow);
          final csv = await service.exportCsv<NearExpiryReportRow>(rows);
          final lineCount = _csvLineCount(csv);

          expect(
            lineCount,
            equals(n + 1),
            reason:
                'Near-expiry CSV with N=$n rows should have ${n + 1} lines '
                '(1 header + $n data rows) but got $lineCount lines.',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Property D: Daily sales report CSV has exactly N+1 lines for N rows.
    //
    // Strategy:
    //   1. Generate N in [0, 10].
    //   2. Build N synthetic DailySalesReport objects.
    //   3. Call exportCsv<DailySalesReport>().
    //   4. Assert the CSV has exactly N+1 lines.
    // -------------------------------------------------------------------------
    Glados(_genN, _exploreConfig).test(
      'daily sales report CSV has exactly N+1 lines for N rows',
      (n) async {
        final db = _openTestDb();
        try {
          final productRepo = ProductRepositoryImpl(db);
          final service = ReportServiceImpl(db, productRepo);

          final rows = List.generate(n, _makeDailySalesRow);
          final csv = await service.exportCsv<DailySalesReport>(rows);
          final lineCount = _csvLineCount(csv);

          expect(
            lineCount,
            equals(n + 1),
            reason:
                'Daily sales CSV with N=$n rows should have ${n + 1} lines '
                '(1 header + $n data rows) but got $lineCount lines.',
          );
        } finally {
          await db.close();
        }
      },
    );
  });
}
