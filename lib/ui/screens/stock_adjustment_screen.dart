import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pharmacy_pos/domain/entities/product.dart';
import 'package:pharmacy_pos/domain/entities/stock_adjustment.dart';
import 'package:pharmacy_pos/domain/entities/user.dart';
import 'package:pharmacy_pos/providers/low_stock_provider.dart';
import 'package:pharmacy_pos/providers/session_timeout_provider.dart';
import 'package:pharmacy_pos/providers/stock_adjustment_provider.dart';

class StockAdjustmentScreen extends ConsumerStatefulWidget {
  const StockAdjustmentScreen({super.key});

  @override
  ConsumerState<StockAdjustmentScreen> createState() =>
      _StockAdjustmentScreenState();
}

class _StockAdjustmentScreenState
    extends ConsumerState<StockAdjustmentScreen> {
  final _formKey = GlobalKey<FormState>();
  final _productSearchCtrl = TextEditingController();
  final _productFocusNode = FocusNode();
  final _deltaCtrl = TextEditingController();

  ProductWithStock? _selectedProduct;
  List<ProductWithStock> _suggestions = [];
  bool _showSuggestions = false;

  AdjustmentReasonCode _reasonCode = AdjustmentReasonCode.damaged;
  String? _inlineError;
  bool _isSaving = false;

  @override
  void dispose() {
    _productSearchCtrl.dispose();
    _productFocusNode.dispose();
    _deltaCtrl.dispose();
    super.dispose();
  }

  void _resetTimer() => ref.read(sessionTimeoutProvider.notifier).resetTimer();

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

  Future<void> _save() async {
    setState(() => _inlineError = null);
    if (!_formKey.currentState!.validate()) return;
    if (_selectedProduct == null) {
      setState(() => _inlineError = 'Please select a product.');
      return;
    }

    setState(() => _isSaving = true);
    try {
      final repo = ref.read(stockAdjustmentRepositoryProvider);
      final authService = ref.read(authServiceProvider);
      final userId = authService.currentUser?.id ?? 'unknown';
      final delta = int.parse(_deltaCtrl.text.trim());

      await repo.create(StockAdjustmentInput(
        productId: _selectedProduct!.product.id,
        userId: userId,
        quantityDelta: delta,
        reasonCode: _reasonCode,
      ));

      // Invalidate product cache so stock levels refresh.
      ref.invalidate(productRepositoryProvider);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Adjustment saved for "${_selectedProduct!.product.name}" '
            '(delta: ${delta >= 0 ? '+' : ''}$delta).',
          ),
        ),
      );
      Navigator.of(context).pop();
    } on StateError catch (e) {
      setState(() => _inlineError = e.message);
    } catch (e) {
      setState(() => _inlineError = e.toString());
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Admin-only guard.
    final user = ref.read(authServiceProvider).currentUser;
    if (user?.role != UserRole.admin) {
      return Scaffold(
        appBar: AppBar(title: const Text('Stock Adjustment')),
        body: const Center(
          child: Text('You do not have permission to perform this action.'),
        ),
      );
    }

    return GestureDetector(
      onTap: _resetTimer,
      child: Scaffold(
        appBar: AppBar(title: const Text('Stock Adjustment')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Product search
                  TextFormField(
                    controller: _productSearchCtrl,
                    focusNode: _productFocusNode,
                    decoration: InputDecoration(
                      labelText: 'Product *',
                      border: const OutlineInputBorder(),
                      suffixIcon: _selectedProduct != null
                          ? const Icon(Icons.check_circle,
                              color: Colors.green)
                          : const Icon(Icons.search),
                    ),
                    validator: (_) => _selectedProduct == null
                        ? 'Please select a product'
                        : null,
                    onChanged: (v) {
                      _resetTimer();
                      if (_selectedProduct != null) {
                        setState(() => _selectedProduct = null);
                      }
                      _searchProducts(v);
                    },
                  ),
                  if (_showSuggestions)
                    Material(
                      elevation: 4,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 200),
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: _suggestions.length,
                          itemBuilder: (_, i) {
                            final ps = _suggestions[i];
                            return ListTile(
                              title: Text(ps.product.name),
                              subtitle: Text(
                                '${ps.product.genericName} — stock: ${ps.stockLevel}',
                              ),
                              onTap: () {
                                setState(() {
                                  _selectedProduct = ps;
                                  _suggestions = [];
                                  _showSuggestions = false;
                                });
                                _productSearchCtrl.text = ps.product.name;
                                _productFocusNode.unfocus();
                                _resetTimer();
                              },
                            );
                          },
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),

                  // Quantity delta
                  TextFormField(
                    controller: _deltaCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Quantity Delta *',
                      helperText: 'Positive to increase, negative to decrease',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                        signed: true),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) return 'Required';
                      if (int.tryParse(v.trim()) == null) {
                        return 'Enter a whole number (e.g. -5 or 10)';
                      }
                      return null;
                    },
                    onChanged: (_) {
                      _resetTimer();
                      if (_inlineError != null) {
                        setState(() => _inlineError = null);
                      }
                    },
                  ),
                  const SizedBox(height: 16),

                  // Reason code dropdown
                  DropdownButtonFormField<AdjustmentReasonCode>(
                    value: _reasonCode,
                    decoration: const InputDecoration(
                      labelText: 'Reason Code *',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: AdjustmentReasonCode.damaged,
                        child: Text('Damaged'),
                      ),
                      DropdownMenuItem(
                        value: AdjustmentReasonCode.expiredRemoval,
                        child: Text('Expired Removal'),
                      ),
                      DropdownMenuItem(
                        value: AdjustmentReasonCode.countCorrection,
                        child: Text('Count Correction'),
                      ),
                      DropdownMenuItem(
                        value: AdjustmentReasonCode.other,
                        child: Text('Other'),
                      ),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => _reasonCode = v);
                      _resetTimer();
                    },
                  ),
                  const SizedBox(height: 24),

                  // Inline error
                  if (_inlineError != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        _inlineError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),

                  FilledButton(
                    onPressed: _isSaving
                        ? null
                        : () {
                            _resetTimer();
                            _save();
                          },
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    child: _isSaving
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Save Adjustment'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
