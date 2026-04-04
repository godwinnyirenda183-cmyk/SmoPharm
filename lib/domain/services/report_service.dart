import '../entities/batch.dart';
import '../entities/product.dart';
import '../entities/sale.dart';

// ---------------------------------------------------------------------------
// Report result types
// ---------------------------------------------------------------------------

/// Daily sales report for a single date.
class DailySalesReport {
  /// Total revenue in integer cents (excludes voided sales).
  final int totalRevenueCents;
  final int transactionCount;
  /// Revenue breakdown by payment method (values in integer cents).
  final Map<PaymentMethod, int> revenueByPaymentMethod;

  const DailySalesReport({
    required this.totalRevenueCents,
    required this.transactionCount,
    required this.revenueByPaymentMethod,
  });
}

/// A single row in the current inventory report.
class InventoryReportRow {
  final Product product;
  final int stockLevel;
  /// Unit cost in integer cents (latest batch cost price).
  final int unitCostCents;
  /// Total stock value in integer cents.
  final int totalValueCents;

  const InventoryReportRow({
    required this.product,
    required this.stockLevel,
    required this.unitCostCents,
    required this.totalValueCents,
  });
}

/// A single row in the low-stock report.
class LowStockReportRow {
  final Product product;
  final int stockLevel;
  final int lowStockThreshold;

  const LowStockReportRow({
    required this.product,
    required this.stockLevel,
    required this.lowStockThreshold,
  });
}

/// A single row in the near-expiry report.
class NearExpiryReportRow {
  final Product product;
  final Batch batch;

  const NearExpiryReportRow({required this.product, required this.batch});
}

// ---------------------------------------------------------------------------
// Service interface
// ---------------------------------------------------------------------------

/// Abstract service for generating operational reports.
abstract class ReportService {
  /// Generates the daily sales report for [date].
  Future<DailySalesReport> dailySalesReport(DateTime date);

  /// Generates the current inventory report for all products.
  Future<List<InventoryReportRow>> inventoryReport();

  /// Generates the low-stock report (products at or below threshold),
  /// sorted by (stockLevel / lowStockThreshold) ascending.
  Future<List<LowStockReportRow>> lowStockReport();

  /// Generates the near-expiry report using the configured window.
  Future<List<NearExpiryReportRow>> nearExpiryReport();

  /// Exports [rows] as a CSV string.
  /// The columns and row order must match the on-screen report exactly.
  Future<String> exportCsv<T>(List<T> rows);
}
