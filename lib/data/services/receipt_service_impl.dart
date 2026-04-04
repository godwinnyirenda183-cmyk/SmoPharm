import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../domain/entities/sale.dart';
import '../../domain/repositories/settings_repository.dart';
import '../../domain/services/receipt_service.dart';

/// Concrete implementation of [ReceiptService] using the `pdf` and `printing`
/// packages.
///
/// [generateReceipt] builds a PDF document in memory and returns the raw bytes.
/// [printReceipt] delegates to [Printing.layoutPdf] for device printing.
class ReceiptServiceImpl implements ReceiptService {
  final SettingsRepository _settings;

  ReceiptServiceImpl(this._settings);

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Formats integer cents as "ZMW 12.50".
  static String _formatZmw(int cents) => formatZmwPublic(cents);

  /// Public alias for [_formatZmw] — exposed for testing.
  static String formatZmwPublic(int cents) {
    final amount = cents / 100.0;
    return 'ZMW ${amount.toStringAsFixed(2)}';
  }

  /// Human-readable payment method label.
  static String _paymentLabel(PaymentMethod method) {
    switch (method) {
      case PaymentMethod.cash:
        return 'Cash';
      case PaymentMethod.mobileMoney:
        return 'Mobile Money';
      case PaymentMethod.insurance:
        return 'Insurance';
    }
  }

  // ---------------------------------------------------------------------------
  // ReceiptService interface
  // ---------------------------------------------------------------------------

  @override
  Future<List<int>> generateReceipt(Sale sale) async {
    final name = await _settings.getPharmacyName();
    final address = await _settings.getPharmacyAddress();
    final phone = await _settings.getPharmacyPhone();

    return generateReceiptWithInfo(
      sale: sale,
      productNames: List.generate(sale.items.length, (i) => sale.items[i].productId),
      pharmacyName: name,
      pharmacyAddress: address,
      pharmacyPhone: phone,
    );
  }

  /// Generates a PDF receipt and returns raw bytes.
  ///
  /// Accepts explicit pharmacy info so it can be called from tests without a
  /// real [SettingsRepository].
  Future<List<int>> generateReceiptWithInfo({
    required Sale sale,
    required List<String> productNames,
    required String pharmacyName,
    required String pharmacyAddress,
    required String pharmacyPhone,
  }) async {
    final doc = pw.Document();

    final date = sale.recordedAt;
    final dateStr =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final timeStr =
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.roll80,
        build: (context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              // ----------------------------------------------------------------
              // Header — pharmacy info
              // ----------------------------------------------------------------
              pw.Center(
                child: pw.Column(
                  children: [
                    pw.Text(
                      pharmacyName.isNotEmpty ? pharmacyName : 'Pharmacy',
                      style: pw.TextStyle(
                        fontSize: 14,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    if (pharmacyAddress.isNotEmpty)
                      pw.Text(pharmacyAddress, style: const pw.TextStyle(fontSize: 10)),
                    if (pharmacyPhone.isNotEmpty)
                      pw.Text('Tel: $pharmacyPhone',
                          style: const pw.TextStyle(fontSize: 10)),
                  ],
                ),
              ),
              pw.SizedBox(height: 8),
              pw.Divider(),
              // ----------------------------------------------------------------
              // Date / time
              // ----------------------------------------------------------------
              pw.Text('Date: $dateStr', style: const pw.TextStyle(fontSize: 10)),
              pw.Text('Time: $timeStr', style: const pw.TextStyle(fontSize: 10)),
              pw.SizedBox(height: 6),
              pw.Divider(),
              // ----------------------------------------------------------------
              // Items table
              // ----------------------------------------------------------------
              pw.Table(
                columnWidths: {
                  0: const pw.FlexColumnWidth(3),
                  1: const pw.FixedColumnWidth(30),
                  2: const pw.FixedColumnWidth(55),
                  3: const pw.FixedColumnWidth(55),
                },
                children: [
                  // Header row
                  pw.TableRow(
                    children: [
                      pw.Text('Item',
                          style: pw.TextStyle(
                              fontSize: 9, fontWeight: pw.FontWeight.bold)),
                      pw.Text('Qty',
                          style: pw.TextStyle(
                              fontSize: 9, fontWeight: pw.FontWeight.bold)),
                      pw.Text('Unit',
                          style: pw.TextStyle(
                              fontSize: 9, fontWeight: pw.FontWeight.bold)),
                      pw.Text('Total',
                          style: pw.TextStyle(
                              fontSize: 9, fontWeight: pw.FontWeight.bold)),
                    ],
                  ),
                  // Item rows
                  for (var i = 0; i < sale.items.length; i++)
                    _buildItemRow(
                      sale.items[i],
                      i < productNames.length
                          ? productNames[i]
                          : sale.items[i].productId,
                    ),
                ],
              ),
              pw.Divider(),
              // ----------------------------------------------------------------
              // Total
              // ----------------------------------------------------------------
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('TOTAL',
                      style: pw.TextStyle(
                          fontSize: 11, fontWeight: pw.FontWeight.bold)),
                  pw.Text(_formatZmw(sale.totalZmw),
                      style: pw.TextStyle(
                          fontSize: 11, fontWeight: pw.FontWeight.bold)),
                ],
              ),
              pw.SizedBox(height: 4),
              // ----------------------------------------------------------------
              // Payment method
              // ----------------------------------------------------------------
              pw.Text('Payment: ${_paymentLabel(sale.paymentMethod)}',
                  style: const pw.TextStyle(fontSize: 10)),
              pw.SizedBox(height: 8),
              pw.Center(
                child: pw.Text('Thank you for your purchase!',
                    style: const pw.TextStyle(fontSize: 9)),
              ),
            ],
          );
        },
      ),
    );

    return doc.save();
  }

  pw.TableRow _buildItemRow(SaleItem item, String productName) {
    return pw.TableRow(
      children: [
        pw.Text(productName, style: const pw.TextStyle(fontSize: 9)),
        pw.Text('${item.quantity}', style: const pw.TextStyle(fontSize: 9)),
        pw.Text(_formatZmw(item.unitPrice), style: const pw.TextStyle(fontSize: 9)),
        pw.Text(_formatZmw(item.lineTotal), style: const pw.TextStyle(fontSize: 9)),
      ],
    );
  }

  @override
  Future<void> printReceipt(List<int> pdfBytes) async {
    await Printing.layoutPdf(
      onLayout: (_) async => Uint8List.fromList(pdfBytes),
    );
  }
}
