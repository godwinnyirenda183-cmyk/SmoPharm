import 'package:csv/csv.dart';
import 'package:drift/drift.dart' hide Batch;
import 'package:pharmacy_pos/database/database.dart' as db_lib;
import 'package:pharmacy_pos/data/repositories/product_repository_impl.dart';
import 'package:pharmacy_pos/domain/entities/batch.dart';
import 'package:pharmacy_pos/domain/entities/product.dart';
import 'package:pharmacy_pos/domain/entities/sale.dart';
import 'package:pharmacy_pos/domain/services/report_service.dart';

/// Concrete implementation of [ReportService] backed by the Drift [AppDatabase].
class ReportServiceImpl implements ReportService {
  final db_lib.AppDatabase _db;
  final ProductRepositoryImpl _productRepo;

  ReportServiceImpl(this._db, this._productRepo);

  // ---------------------------------------------------------------------------
  // dailySalesReport
  // ---------------------------------------------------------------------------

  @override
  Future<DailySalesReport> dailySalesReport(DateTime date) async {
    // Define the start and end of the requested day.
    final dayStart = DateTime(date.year, date.month, date.day);
    final dayEnd = dayStart.add(const Duration(days: 1));

    // Fetch all non-voided sales on that day.
    final rows = await (_db.select(_db.sales)
          ..where(
            (s) =>
                s.recordedAt.isBiggerOrEqualValue(dayStart) &
                s.recordedAt.isSmallerThanValue(dayEnd) &
                s.voided.equals(false),
          ))
        .get();

    int totalRevenueCents = 0;
    final Map<PaymentMethod, int> revenueByPaymentMethod = {};

    for (final row in rows) {
      totalRevenueCents += row.totalZmw;
      final method = _paymentMethodFromString(row.paymentMethod);
      revenueByPaymentMethod[method] =
          (revenueByPaymentMethod[method] ?? 0) + row.totalZmw;
    }

    return DailySalesReport(
      totalRevenueCents: totalRevenueCents,
      transactionCount: rows.length,
      revenueByPaymentMethod: revenueByPaymentMethod,
    );
  }

  // ---------------------------------------------------------------------------
  // inventoryReport
  // ---------------------------------------------------------------------------

  @override
  Future<List<InventoryReportRow>> inventoryReport() async {
    final productRows = await _db.select(_db.products).get();
    final result = <InventoryReportRow>[];

    for (final productRow in productRows) {
      // Non-expired batches for this product.
      final batches = await (_db.select(_db.batches)
            ..where(
              (b) =>
                  b.productId.equals(productRow.id) &
                  b.status.isNotIn(const ['expired']),
            ))
          .get();

      final stockLevel =
          batches.fold<int>(0, (sum, b) => sum + b.quantityRemaining);

      // Total value = sum of (quantity_remaining * cost_price_per_unit).
      final totalValueCents = batches.fold<int>(
          0, (sum, b) => sum + b.quantityRemaining * b.costPricePerUnit);

      // Unit cost = latest batch cost (most recently received non-expired batch).
      // Falls back to 0 if no batches.
      int unitCostCents = 0;
      if (batches.isNotEmpty) {
        final sorted = List.of(batches)
          ..sort((a, b) => b.receivedDate.compareTo(a.receivedDate));
        unitCostCents = sorted.first.costPricePerUnit;
      }

      result.add(InventoryReportRow(
        product: _productRowToEntity(productRow),
        stockLevel: stockLevel,
        unitCostCents: unitCostCents,
        totalValueCents: totalValueCents,
      ));
    }

    return result;
  }

  // ---------------------------------------------------------------------------
  // lowStockReport
  // ---------------------------------------------------------------------------

  @override
  Future<List<LowStockReportRow>> lowStockReport() async {
    final lowStock = await _productRepo.listLowStock();

    return lowStock
        .map((p) => LowStockReportRow(
              product: p.product,
              stockLevel: p.stockLevel,
              lowStockThreshold: p.product.lowStockThreshold,
            ))
        .toList();
  }

  // ---------------------------------------------------------------------------
  // nearExpiryReport
  // ---------------------------------------------------------------------------

  @override
  Future<List<NearExpiryReportRow>> nearExpiryReport() async {
    // Fetch all near_expiry batches.
    final batchRows = await (_db.select(_db.batches)
          ..where((b) => b.status.equals('near_expiry')))
        .get();

    final result = <NearExpiryReportRow>[];

    for (final batchRow in batchRows) {
      final productRow = await (_db.select(_db.products)
            ..where((p) => p.id.equals(batchRow.productId)))
          .getSingleOrNull();

      if (productRow == null) continue;

      result.add(NearExpiryReportRow(
        product: _productRowToEntity(productRow),
        batch: _batchRowToEntity(batchRow),
      ));
    }

    return result;
  }

  // ---------------------------------------------------------------------------
  // exportCsv
  // ---------------------------------------------------------------------------

  @override
  Future<String> exportCsv<T>(List<T> rows) async {
    final List<List<dynamic>> table;

    if (rows is List<DailySalesReport>) {
      table = _dailySalesCsvTable(rows as List<DailySalesReport>);
    } else if (rows is List<InventoryReportRow>) {
      table = _inventoryCsvTable(rows as List<InventoryReportRow>);
    } else if (rows is List<LowStockReportRow>) {
      table = _lowStockCsvTable(rows as List<LowStockReportRow>);
    } else if (rows is List<NearExpiryReportRow>) {
      table = _nearExpiryCsvTable(rows as List<NearExpiryReportRow>);
    } else {
      throw ArgumentError('Unsupported report type: ${T.toString()}');
    }

    return const ListToCsvConverter().convert(table);
  }

  List<List<dynamic>> _dailySalesCsvTable(List<DailySalesReport> rows) {
    final header = [
      'Date',
      'Total Revenue (ZMW)',
      'Transaction Count',
      'Cash Revenue (ZMW)',
      'Mobile Money Revenue (ZMW)',
      'Insurance Revenue (ZMW)',
    ];
    final dataRows = rows.map((r) {
      final cash = r.revenueByPaymentMethod[PaymentMethod.cash] ?? 0;
      final mobile = r.revenueByPaymentMethod[PaymentMethod.mobileMoney] ?? 0;
      final insurance = r.revenueByPaymentMethod[PaymentMethod.insurance] ?? 0;
      return [
        '', // Date is not stored on DailySalesReport; left blank
        _centsToZmw(r.totalRevenueCents),
        r.transactionCount,
        _centsToZmw(cash),
        _centsToZmw(mobile),
        _centsToZmw(insurance),
      ];
    }).toList();
    return [header, ...dataRows];
  }

  List<List<dynamic>> _inventoryCsvTable(List<InventoryReportRow> rows) {
    final header = [
      'Product Name',
      'Generic Name',
      'Category',
      'Unit of Measure',
      'Stock Level',
      'Unit Cost (ZMW)',
      'Total Value (ZMW)',
    ];
    final dataRows = rows.map((r) => [
          r.product.name,
          r.product.genericName,
          r.product.category,
          r.product.unitOfMeasure,
          r.stockLevel,
          _centsToZmw(r.unitCostCents),
          _centsToZmw(r.totalValueCents),
        ]).toList();
    return [header, ...dataRows];
  }

  List<List<dynamic>> _lowStockCsvTable(List<LowStockReportRow> rows) {
    final header = [
      'Product Name',
      'Generic Name',
      'Stock Level',
      'Low Stock Threshold',
    ];
    final dataRows = rows.map((r) => [
          r.product.name,
          r.product.genericName,
          r.stockLevel,
          r.lowStockThreshold,
        ]).toList();
    return [header, ...dataRows];
  }

  List<List<dynamic>> _nearExpiryCsvTable(List<NearExpiryReportRow> rows) {
    final header = [
      'Product Name',
      'Batch Number',
      'Expiry Date',
      'Quantity Remaining',
    ];
    final dataRows = rows.map((r) => [
          r.product.name,
          r.batch.batchNumber,
          r.batch.expiryDate.toIso8601String().substring(0, 10),
          r.batch.quantityRemaining,
        ]).toList();
    return [header, ...dataRows];
  }

  /// Converts integer cents to a ZMW string with 2 decimal places.
  String _centsToZmw(int cents) => (cents / 100).toStringAsFixed(2);

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  PaymentMethod _paymentMethodFromString(String s) {
    switch (s) {
      case 'Mobile_Money':
        return PaymentMethod.mobileMoney;
      case 'Insurance':
        return PaymentMethod.insurance;
      default:
        return PaymentMethod.cash;
    }
  }

  Product _productRowToEntity(dynamic row) {
    return Product(
      id: row.id as String,
      name: row.name as String,
      genericName: row.genericName as String,
      category: row.category as String,
      unitOfMeasure: row.unitOfMeasure as String,
      sellingPrice: row.sellingPrice as int,
      lowStockThreshold: row.lowStockThreshold as int,
      createdAt: row.createdAt as DateTime,
      updatedAt: row.updatedAt as DateTime,
    );
  }

  Batch _batchRowToEntity(dynamic row) {
    return Batch(
      id: row.id as String,
      productId: row.productId as String,
      batchNumber: row.batchNumber as String,
      expiryDate: row.expiryDate as DateTime,
      supplierName: row.supplierName as String,
      quantityReceived: row.quantityReceived as int,
      quantityRemaining: row.quantityRemaining as int,
      costPricePerUnit: row.costPricePerUnit as int,
      receivedDate: row.receivedDate as DateTime,
      status: _batchStatusFromString(row.status as String),
    );
  }

  BatchStatus _batchStatusFromString(String s) {
    switch (s) {
      case 'expired':
        return BatchStatus.expired;
      case 'near_expiry':
        return BatchStatus.nearExpiry;
      default:
        return BatchStatus.active;
    }
  }
}
