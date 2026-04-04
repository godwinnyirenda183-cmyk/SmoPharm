import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_pos/data/services/receipt_service_impl.dart';
import 'package:pharmacy_pos/domain/entities/sale.dart';
import 'package:pharmacy_pos/domain/repositories/settings_repository.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Sale _makeSale({
  PaymentMethod paymentMethod = PaymentMethod.cash,
  List<SaleItem>? items,
}) {
  final saleItems = items ??
      [
        const SaleItem(
          id: 'item-1',
          saleId: 'sale-1',
          productId: 'prod-1',
          batchId: 'batch-1',
          quantity: 2,
          unitPrice: 1250, // ZMW 12.50
          lineTotal: 2500, // ZMW 25.00
        ),
        const SaleItem(
          id: 'item-2',
          saleId: 'sale-1',
          productId: 'prod-2',
          batchId: 'batch-2',
          quantity: 1,
          unitPrice: 500, // ZMW 5.00
          lineTotal: 500,
        ),
      ];

  return Sale(
    id: 'sale-1',
    userId: 'user-1',
    recordedAt: DateTime(2024, 6, 15, 10, 30),
    totalZmw: saleItems.fold(0, (sum, i) => sum + i.lineTotal),
    paymentMethod: paymentMethod,
    voided: false,
    items: saleItems,
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('ReceiptServiceImpl.generateReceiptWithInfo', () {
    late ReceiptServiceImpl service;

    setUp(() {
      // We use a stub SettingsRepository — tests call generateReceiptWithInfo
      // directly so no real repository is needed.
      service = ReceiptServiceImpl(_StubSettingsRepository());
    });

    test('returns non-empty bytes for a basic sale', () async {
      final sale = _makeSale();
      final bytes = await service.generateReceiptWithInfo(
        sale: sale,
        productNames: ['Paracetamol 500mg', 'Amoxicillin 250mg'],
        pharmacyName: 'City Pharmacy',
        pharmacyAddress: '123 Cairo Road, Lusaka',
        pharmacyPhone: '+260 211 123456',
      );

      expect(bytes, isNotEmpty);
    });

    test('PDF bytes start with the PDF magic header (%PDF)', () async {
      final sale = _makeSale();
      final bytes = await service.generateReceiptWithInfo(
        sale: sale,
        productNames: ['Paracetamol 500mg'],
        pharmacyName: 'Test Pharmacy',
        pharmacyAddress: 'Test Address',
        pharmacyPhone: '0211-000000',
      );

      // PDF files always start with "%PDF"
      final header = String.fromCharCodes(bytes.take(4));
      expect(header, equals('%PDF'));
    });

    test('generates receipt with cash payment method', () async {
      final sale = _makeSale(paymentMethod: PaymentMethod.cash);
      final bytes = await service.generateReceiptWithInfo(
        sale: sale,
        productNames: ['Aspirin'],
        pharmacyName: 'Pharmacy',
        pharmacyAddress: '',
        pharmacyPhone: '',
      );
      expect(bytes, isNotEmpty);
    });

    test('generates receipt with mobile money payment method', () async {
      final sale = _makeSale(paymentMethod: PaymentMethod.mobileMoney);
      final bytes = await service.generateReceiptWithInfo(
        sale: sale,
        productNames: ['Aspirin'],
        pharmacyName: 'Pharmacy',
        pharmacyAddress: '',
        pharmacyPhone: '',
      );
      expect(bytes, isNotEmpty);
    });

    test('generates receipt with insurance payment method', () async {
      final sale = _makeSale(paymentMethod: PaymentMethod.insurance);
      final bytes = await service.generateReceiptWithInfo(
        sale: sale,
        productNames: ['Aspirin'],
        pharmacyName: 'Pharmacy',
        pharmacyAddress: '',
        pharmacyPhone: '',
      );
      expect(bytes, isNotEmpty);
    });

    test('generates receipt with empty pharmacy info', () async {
      final sale = _makeSale();
      final bytes = await service.generateReceiptWithInfo(
        sale: sale,
        productNames: ['Drug A', 'Drug B'],
        pharmacyName: '',
        pharmacyAddress: '',
        pharmacyPhone: '',
      );
      expect(bytes, isNotEmpty);
    });

    test('generates receipt for sale with single item', () async {
      final sale = _makeSale(
        items: [
          const SaleItem(
            id: 'item-1',
            saleId: 'sale-1',
            productId: 'prod-1',
            batchId: 'batch-1',
            quantity: 3,
            unitPrice: 750,
            lineTotal: 2250,
          ),
        ],
      );
      final bytes = await service.generateReceiptWithInfo(
        sale: sale,
        productNames: ['Ibuprofen 400mg'],
        pharmacyName: 'Health Plus',
        pharmacyAddress: 'Ndola',
        pharmacyPhone: '0212-000000',
      );
      expect(bytes, isNotEmpty);
    });

    test('formatZmw formats cents correctly', () {
      // 1250 cents → ZMW 12.50
      expect(ReceiptServiceImpl.formatZmwPublic(1250), equals('ZMW 12.50'));
      // 100 cents → ZMW 1.00
      expect(ReceiptServiceImpl.formatZmwPublic(100), equals('ZMW 1.00'));
      // 0 cents → ZMW 0.00
      expect(ReceiptServiceImpl.formatZmwPublic(0), equals('ZMW 0.00'));
      // 99 cents → ZMW 0.99
      expect(ReceiptServiceImpl.formatZmwPublic(99), equals('ZMW 0.99'));
    });
  });
}

// ---------------------------------------------------------------------------
// Stub
// ---------------------------------------------------------------------------

class _StubSettingsRepository implements SettingsRepository {
  @override
  Future<String?> get(String key) async => null;
  @override
  Future<void> set(String key, String value) async {}
  @override
  Future<String> getPharmacyName() async => '';
  @override
  Future<void> setPharmacyName(String name) async {}
  @override
  Future<String> getPharmacyAddress() async => '';
  @override
  Future<void> setPharmacyAddress(String address) async {}
  @override
  Future<String> getPharmacyPhone() async => '';
  @override
  Future<void> setPharmacyPhone(String phone) async {}
  @override
  Future<int> getNearExpiryWindowDays() async => 90;
  @override
  Future<void> setNearExpiryWindowDays(int days) async {}
}
