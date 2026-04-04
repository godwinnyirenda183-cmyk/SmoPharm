import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pharmacy_pos/data/services/receipt_service_impl.dart';
import 'package:pharmacy_pos/domain/entities/product.dart';
import 'package:pharmacy_pos/domain/entities/sale.dart';
import 'package:pharmacy_pos/providers/batch_provider.dart';
import 'package:pharmacy_pos/providers/low_stock_provider.dart';
import 'package:pharmacy_pos/providers/sale_provider.dart';
import 'package:pharmacy_pos/providers/session_timeout_provider.dart';
import 'package:pharmacy_pos/providers/settings_provider.dart';

// ---------------------------------------------------------------------------
// _CartItem — one line in the cart
// ---------------------------------------------------------------------------

class _CartItem {
  final ProductWithStock productWithStock;
  /// FEFO batch expiry date (nullable if no batch found yet).
  final DateTime? batchExpiry;
  int quantity;

  _CartItem({
    required this.productWithStock,
    required this.batchExpiry,
    this.quantity = 1,
  });

  int get unitPrice => productWithStock.product.sellingPrice;
  int get lineTotal => unitPrice * quantity;
  String get productName => productWithStock.product.name;
  int get stockLevel => productWithStock.stockLevel;
}

// ---------------------------------------------------------------------------
// PosScreen
// ---------------------------------------------------------------------------

class PosScreen extends ConsumerStatefulWidget {
  const PosScreen({super.key});

  @override
  ConsumerState<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends ConsumerState<PosScreen> {
  final _searchCtrl = TextEditingController();
  final _searchFocusNode = FocusNode();

  List<ProductWithStock> _suggestions = [];
  bool _showSuggestions = false;

  final List<_CartItem> _cart = [];
  PaymentMethod _paymentMethod = PaymentMethod.cash;
  String? _inlineError;
  bool _isConfirming = false;

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _resetTimer() => ref.read(sessionTimeoutProvider.notifier).resetTimer();

  // ---------------------------------------------------------------------------
  // Product search
  // ---------------------------------------------------------------------------

  Future<void> _searchProducts(String query) async {
    if (query.isEmpty) {
      setState(() {
        _suggestions = [];
        _showSuggestions = false;
      });
      return;
    }
    final repo = ref.read(productRepositoryProvider);
    final results = await repo.search(query);
    final all = await repo.listAll();
    final matchIds = results.map((p) => p.id).toSet();
    final withStock =
        all.where((ps) => matchIds.contains(ps.product.id)).toList();
    setState(() {
      _suggestions = withStock;
      _showSuggestions = withStock.isNotEmpty;
    });
  }

  // ---------------------------------------------------------------------------
  // Add product to cart
  // ---------------------------------------------------------------------------

  Future<void> _addToCart(ProductWithStock ps) async {
    _searchCtrl.clear();
    _searchFocusNode.unfocus();
    setState(() {
      _suggestions = [];
      _showSuggestions = false;
      _inlineError = null;
    });

    // Check if already in cart — just increment quantity.
    final existing = _cart.indexWhere(
        (c) => c.productWithStock.product.id == ps.product.id);
    if (existing >= 0) {
      setState(() => _cart[existing].quantity++);
      return;
    }

    // Fetch FEFO batch expiry for display purposes.
    DateTime? batchExpiry;
    try {
      final batchRepo = ref.read(batchRepositoryProvider);
      final fefo = await batchRepo.selectFEFO(ps.product.id, 1);
      batchExpiry = fefo?.expiryDate;
    } catch (_) {}

    setState(() {
      _cart.add(_CartItem(
        productWithStock: ps,
        batchExpiry: batchExpiry,
        quantity: 1,
      ));
    });
  }

  // ---------------------------------------------------------------------------
  // Cart helpers
  // ---------------------------------------------------------------------------

  void _removeFromCart(int index) {
    setState(() {
      _cart.removeAt(index);
      _inlineError = null;
    });
  }

  void _setQuantity(int index, int qty) {
    if (qty < 1) return;
    setState(() {
      _cart[index].quantity = qty;
      _inlineError = null;
    });
  }

  int get _totalCents =>
      _cart.fold(0, (sum, item) => sum + item.lineTotal);

  // ---------------------------------------------------------------------------
  // Confirm sale
  // ---------------------------------------------------------------------------

  Future<void> _confirmSale() async {
    if (_cart.isEmpty) {
      setState(() => _inlineError = 'Cart is empty. Add at least one item.');
      return;
    }

    setState(() {
      _inlineError = null;
      _isConfirming = true;
    });

    try {
      final saleRepo = ref.read(saleRepositoryProvider);
      final authService = ref.read(authServiceProvider);
      final userId = authService.currentUser?.id ?? 'unknown';

      final input = SaleInput(
        userId: userId,
        paymentMethod: _paymentMethod,
        items: _cart
            .map((c) => SaleItemInput(
                  productId: c.productWithStock.product.id,
                  quantity: c.quantity,
                ))
            .toList(),
      );

      final sale = await saleRepo.create(input);

      // Generate receipt.
      List<int>? pdfBytes;
      try {
        final receiptService = ReceiptServiceImpl(
          ref.read(settingsRepositoryProvider),
        );
        pdfBytes = await receiptService.generateReceipt(sale);
      } catch (_) {
        // Receipt failure does not undo the sale.
      }

      // Invalidate product cache so stock levels refresh.
      ref.invalidate(productRepositoryProvider);

      if (!mounted) return;

      // Clear cart.
      setState(() => _cart.clear());

      // Show success dialog / snackbar.
      if (pdfBytes != null) {
        _showReceiptDialog(sale, pdfBytes);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Sale confirmed — total ${_formatZmw(sale.totalZmw)}. '
              'Receipt generation failed; sale is recorded.',
            ),
          ),
        );
      }
    } on StateError catch (e) {
      setState(() => _inlineError = e.message);
    } catch (e) {
      setState(() => _inlineError = e.toString());
    } finally {
      if (mounted) setState(() => _isConfirming = false);
    }
  }

  void _showReceiptDialog(Sale sale, List<int> pdfBytes) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Sale Confirmed'),
        content: Text(
          'Total: ${_formatZmw(sale.totalZmw)}\n'
          'Payment: ${_paymentLabel(sale.paymentMethod)}\n\n'
          'Receipt generated successfully.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(context).pop();
              try {
                final receiptService = ReceiptServiceImpl(
                  ref.read(settingsRepositoryProvider),
                );
                await receiptService.printReceipt(pdfBytes);
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Print failed: $e')),
                  );
                }
              }
            },
            child: const Text('Print Receipt'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Formatting helpers
  // ---------------------------------------------------------------------------

  static String _formatZmw(int cents) {
    return 'ZMW ${(cents / 100.0).toStringAsFixed(2)}';
  }

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
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return GestureDetector(
      onTap: _resetTimer,
      child: Scaffold(
        appBar: AppBar(title: const Text('POS / Sale')),
        body: Column(
          children: [
            // ----------------------------------------------------------------
            // Product search
            // ----------------------------------------------------------------
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    controller: _searchCtrl,
                    focusNode: _searchFocusNode,
                    decoration: const InputDecoration(
                      labelText: 'Search product by name or generic name',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (v) {
                      _resetTimer();
                      _searchProducts(v);
                    },
                  ),
                  if (_showSuggestions)
                    Material(
                      elevation: 4,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 220),
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: _suggestions.length,
                          itemBuilder: (_, i) {
                            final ps = _suggestions[i];
                            return ListTile(
                              title: Text(ps.product.name),
                              subtitle: Text(
                                '${ps.product.genericName} · '
                                'Price: ${_formatZmw(ps.product.sellingPrice)} · '
                                'Stock: ${ps.stockLevel}',
                              ),
                              trailing: FilledButton.tonal(
                                onPressed: () {
                                  _resetTimer();
                                  _addToCart(ps);
                                },
                                child: const Text('Add'),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // ----------------------------------------------------------------
            // Cart list
            // ----------------------------------------------------------------
            Expanded(
              child: _cart.isEmpty
                  ? Center(
                      child: Text(
                        'No items in cart',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: theme.hintColor),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: _cart.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, index) =>
                          _CartItemTile(
                            item: _cart[index],
                            onRemove: () => _removeFromCart(index),
                            onQuantityChanged: (q) => _setQuantity(index, q),
                          ),
                    ),
            ),

            // ----------------------------------------------------------------
            // Bottom panel: total, payment, error, confirm
            // ----------------------------------------------------------------
            _BottomPanel(
              totalCents: _totalCents,
              paymentMethod: _paymentMethod,
              inlineError: _inlineError,
              isConfirming: _isConfirming,
              onPaymentChanged: (m) {
                setState(() => _paymentMethod = m);
                _resetTimer();
              },
              onConfirm: () {
                _resetTimer();
                _confirmSale();
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _CartItemTile
// ---------------------------------------------------------------------------

class _CartItemTile extends StatelessWidget {
  const _CartItemTile({
    required this.item,
    required this.onRemove,
    required this.onQuantityChanged,
  });

  final _CartItem item;
  final VoidCallback onRemove;
  final void Function(int) onQuantityChanged;

  static String _fmt(int cents) =>
      'ZMW ${(cents / 100.0).toStringAsFixed(2)}';

  static String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Product info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.productName,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                  'Unit: ${_fmt(item.unitPrice)} · Stock: ${item.stockLevel}'
                  '${item.batchExpiry != null ? ' · Expiry: ${_fmtDate(item.batchExpiry!)}' : ''}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.hintColor),
                ),
                const SizedBox(height: 4),
                Text(
                  'Line total: ${_fmt(item.lineTotal)}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          // Quantity stepper
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.remove_circle_outline),
                iconSize: 20,
                onPressed: item.quantity > 1
                    ? () => onQuantityChanged(item.quantity - 1)
                    : null,
              ),
              SizedBox(
                width: 32,
                child: Text(
                  '${item.quantity}',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add_circle_outline),
                iconSize: 20,
                onPressed: () => onQuantityChanged(item.quantity + 1),
              ),
            ],
          ),
          // Remove button
          IconButton(
            icon: Icon(Icons.delete_outline,
                color: theme.colorScheme.error),
            iconSize: 20,
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _BottomPanel
// ---------------------------------------------------------------------------

class _BottomPanel extends StatelessWidget {
  const _BottomPanel({
    required this.totalCents,
    required this.paymentMethod,
    required this.inlineError,
    required this.isConfirming,
    required this.onPaymentChanged,
    required this.onConfirm,
  });

  final int totalCents;
  final PaymentMethod paymentMethod;
  final String? inlineError;
  final bool isConfirming;
  final void Function(PaymentMethod) onPaymentChanged;
  final VoidCallback onConfirm;

  static String _fmt(int cents) =>
      'ZMW ${(cents / 100.0).toStringAsFixed(2)}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Total
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Total',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
              Text(
                _fmt(totalCents),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Payment method selector
          SegmentedButton<PaymentMethod>(
            segments: const [
              ButtonSegment(
                value: PaymentMethod.cash,
                label: Text('Cash'),
                icon: Icon(Icons.payments_outlined),
              ),
              ButtonSegment(
                value: PaymentMethod.mobileMoney,
                label: Text('Mobile Money'),
                icon: Icon(Icons.phone_android),
              ),
              ButtonSegment(
                value: PaymentMethod.insurance,
                label: Text('Insurance'),
                icon: Icon(Icons.health_and_safety_outlined),
              ),
            ],
            selected: {paymentMethod},
            onSelectionChanged: (s) => onPaymentChanged(s.first),
          ),
          const SizedBox(height: 12),

          // Inline error
          if (inlineError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                inlineError!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),

          // Confirm button
          FilledButton(
            onPressed: isConfirming ? null : onConfirm,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            child: isConfirming
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Confirm Sale'),
          ),
        ],
      ),
    );
  }
}
