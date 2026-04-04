/// Batch status derived from expiry date vs. near-expiry window.
enum BatchStatus { active, nearExpiry, expired }

/// Domain entity for a product batch/lot.
/// All monetary values are integer cents.
class Batch {
  final String id;
  final String productId;
  final String batchNumber;
  final DateTime expiryDate;
  final String supplierName;
  final int quantityReceived;
  final int quantityRemaining;
  /// Cost price per unit in integer cents.
  final int costPricePerUnit;
  final DateTime receivedDate;
  final BatchStatus status;

  const Batch({
    required this.id,
    required this.productId,
    required this.batchNumber,
    required this.expiryDate,
    required this.supplierName,
    required this.quantityReceived,
    required this.quantityRemaining,
    required this.costPricePerUnit,
    required this.receivedDate,
    required this.status,
  });
}

/// Input DTO for creating a batch (used within a StockIn event).
class BatchInput {
  final String productId;
  final String batchNumber;
  final DateTime expiryDate;
  final String supplierName;
  final int quantityReceived;
  /// Cost price per unit in integer cents.
  final int costPricePerUnit;

  const BatchInput({
    required this.productId,
    required this.batchNumber,
    required this.expiryDate,
    required this.supplierName,
    required this.quantityReceived,
    required this.costPricePerUnit,
  });
}
