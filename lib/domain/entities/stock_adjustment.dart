/// Reason codes for a stock adjustment.
enum AdjustmentReasonCode {
  damaged,
  expiredRemoval,
  countCorrection,
  other,
}

/// Domain entity for a manual stock adjustment.
class StockAdjustment {
  final String id;
  final String productId;
  final String userId;
  /// Positive = increase, negative = decrease.
  final int quantityDelta;
  final AdjustmentReasonCode reasonCode;
  final DateTime recordedAt;

  const StockAdjustment({
    required this.id,
    required this.productId,
    required this.userId,
    required this.quantityDelta,
    required this.reasonCode,
    required this.recordedAt,
  });
}

/// Input DTO for recording a stock adjustment.
class StockAdjustmentInput {
  final String productId;
  final String userId;
  /// Positive = increase, negative = decrease.
  final int quantityDelta;
  final AdjustmentReasonCode reasonCode;

  const StockAdjustmentInput({
    required this.productId,
    required this.userId,
    required this.quantityDelta,
    required this.reasonCode,
  });
}
