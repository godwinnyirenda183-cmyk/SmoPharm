import '../entities/stock_adjustment.dart';

/// Abstract repository for stock adjustments.
/// Saved records are immutable — no update or delete operations are exposed.
abstract class StockAdjustmentRepository {
  /// Records a stock adjustment and applies the delta to batch quantities.
  /// Throws [StateError] if the resulting stock level would be negative.
  Future<StockAdjustment> create(StockAdjustmentInput input);

  /// Returns all adjustments for [productId] in chronological order.
  Future<List<StockAdjustment>> listForProduct(String productId);
}
