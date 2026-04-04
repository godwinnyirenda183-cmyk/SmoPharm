import '../entities/batch.dart';
import '../entities/stock_in.dart';

/// Input DTO that bundles a new batch definition with the received quantity.
class StockInBatchInput {
  final BatchInput batchInput;
  final int quantity;

  const StockInBatchInput({required this.batchInput, required this.quantity});
}

/// Full input DTO for recording a stock-in event with one or more batches.
class StockInCreateInput {
  final String userId;
  final List<StockInBatchInput> batches;

  const StockInCreateInput({required this.userId, required this.batches});
}

/// Abstract repository for recording stock receipts.
abstract class StockInRepository {
  /// Records a stock-in event: creates batch records and increments
  /// [quantity_remaining] for each batch.
  /// Throws [ArgumentError] if any quantity is ≤ 0.
  Future<StockIn> create(StockInCreateInput input);
}
