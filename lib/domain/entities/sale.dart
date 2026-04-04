/// Payment methods accepted at the POS.
enum PaymentMethod { cash, mobileMoney, insurance }

/// A single line item within a sale.
/// All monetary values are integer cents.
class SaleItem {
  final String id;
  final String saleId;
  final String productId;
  final String batchId;
  final int quantity;
  /// Unit price in integer cents.
  final int unitPrice;
  /// Line total in integer cents (quantity * unitPrice).
  final int lineTotal;

  const SaleItem({
    required this.id,
    required this.saleId,
    required this.productId,
    required this.batchId,
    required this.quantity,
    required this.unitPrice,
    required this.lineTotal,
  });
}

/// Domain entity for a completed sale transaction.
/// All monetary values are integer cents.
class Sale {
  final String id;
  final String userId;
  final DateTime recordedAt;
  /// Total in integer cents.
  final int totalZmw;
  final PaymentMethod paymentMethod;
  final bool voided;
  final String? voidReason;
  final DateTime? voidedAt;
  final List<SaleItem> items;

  const Sale({
    required this.id,
    required this.userId,
    required this.recordedAt,
    required this.totalZmw,
    required this.paymentMethod,
    required this.voided,
    this.voidReason,
    this.voidedAt,
    required this.items,
  });
}

/// Input DTO for a single sale item.
class SaleItemInput {
  final String productId;
  final int quantity;

  const SaleItemInput({required this.productId, required this.quantity});
}

/// Input DTO for creating a sale.
class SaleInput {
  final String userId;
  final PaymentMethod paymentMethod;
  final List<SaleItemInput> items;

  const SaleInput({
    required this.userId,
    required this.paymentMethod,
    required this.items,
  });
}
