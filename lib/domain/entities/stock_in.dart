/// A single line within a StockIn event, linking a batch to a quantity.
class StockInLine {
  final String id;
  final String stockInId;
  final String batchId;
  final int quantity;

  const StockInLine({
    required this.id,
    required this.stockInId,
    required this.batchId,
    required this.quantity,
  });
}

/// Domain entity for a stock receipt event.
class StockIn {
  final String id;
  final String userId;
  final DateTime recordedAt;
  final List<StockInLine> lines;

  const StockIn({
    required this.id,
    required this.userId,
    required this.recordedAt,
    required this.lines,
  });
}

/// Input DTO for a single line within a StockIn event.
class StockInLineInput {
  /// Pre-built BatchInput for the new batch being received.
  final String batchId;
  final int quantity;

  const StockInLineInput({required this.batchId, required this.quantity});
}

/// Input DTO for recording a stock-in event.
class StockInInput {
  final String userId;
  /// Each element pairs a batch with the quantity received.
  final List<StockInLineInput> lines;

  const StockInInput({required this.userId, required this.lines});
}
