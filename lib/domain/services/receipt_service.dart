import '../entities/sale.dart';

/// Abstract service for generating printable PDF receipts.
abstract class ReceiptService {
  /// Generates a PDF receipt for [sale] and returns the raw PDF bytes.
  /// The receipt must include: pharmacy name, address, phone, date, time,
  /// all sale items with quantities and unit prices, total in ZMW, and
  /// payment method.
  /// Throws [Exception] if PDF generation fails (the sale is still recorded).
  Future<List<int>> generateReceipt(Sale sale);

  /// Sends [pdfBytes] to the default printer.
  Future<void> printReceipt(List<int> pdfBytes);
}
