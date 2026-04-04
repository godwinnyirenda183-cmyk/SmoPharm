import '../entities/sale.dart';

/// Abstract repository for sales recording and voiding.
abstract class SaleRepository {
  /// Creates a sale: applies FEFO batch selection, decrements stock, and
  /// persists the sale with all items.
  /// Throws [StateError] if any item quantity exceeds available stock.
  Future<Sale> create(SaleInput input);

  /// Voids a sale by [saleId], restoring decremented stock quantities.
  /// [reason] is mandatory.
  /// Throws [StateError] if the sale was not recorded on the current business
  /// day, or if it is already voided.
  Future<void> voidSale(String saleId, String reason);
}
