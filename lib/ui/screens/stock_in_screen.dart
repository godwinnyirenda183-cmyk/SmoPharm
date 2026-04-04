import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pharmacy_pos/domain/entities/batch.dart';
import 'package:pharmacy_pos/domain/entities/product.dart';
import 'package:pharmacy_pos/domain/repositories/stock_in_repository.dart';
import 'package:pharmacy_pos/providers/low_stock_provider.dart';
import 'package:pharmacy_pos/providers/session_timeout_provider.dart';
import 'package:pharmacy_pos/providers/stock_in_provider.dart';

// ---------------------------------------------------------------------------
// _BatchLineData — mutable state for one batch line in the form
// ---------------------------------------------------------------------------

class _BatchLineData {
  ProductWithStock? selectedProduct;
  final TextEditingController batchNumberCtrl = TextEditingController();
  DateTime? expiryDate;
  final TextEditingController supplierCtrl = TextEditingController();
  final TextEditingController quantityCtrl = TextEditingController();
  final TextEditingController costPriceCtrl = TextEditingController();

  String? quantityError;

  void dispose() {
    batchNumberCtrl.dispose();
    supplierCtrl.dispose();
    quantityCtrl.dispose();
    costPriceCtrl.dispose();
  }
}

// ---------------------------------------------------------------------------
// StockInScreen
// ---------------------------------------------------------------------------

class StockInScreen extends ConsumerStatefulWidget {
  const StockInScreen({super.key});

  @override
  ConsumerState<StockInScreen> createState() => _StockInScreenState();
}

class _StockInScreenState extends ConsumerState<StockInScreen> {
  final _formKey = GlobalKey<FormState>();
  final List<_BatchLineData> _lines = [];
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _addLine();
  }

  @override
  void dispose() {
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  void _resetTimer() => ref.read(sessionTimeoutProvider.notifier).resetTimer();

  void _addLine() {
    setState(() => _lines.add(_BatchLineData()));
  }

  void _removeLine(int index) {
    setState(() {
      _lines[index].dispose();
      _lines.removeAt(index);
    });
  }

  Future<void> _pickExpiry(int index) async {
    _resetTimer();
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now.add(const Duration(days: 365)),
      firstDate: now,
      lastDate: DateTime(now.year + 20),
    );
    if (picked != null) {
      setState(() => _lines[index].expiryDate = picked);
    }
  }

  bool _validateLines() {
    bool valid = true;
    for (final line in _lines) {
      final qty = int.tryParse(line.quantityCtrl.text.trim()) ?? 0;
      if (qty <= 0) {
        line.quantityError = 'Quantity must be greater than zero';
        valid = false;
      } else {
        line.quantityError = null;
      }
    }
    setState(() {});
    return valid;
  }

  Future<void> _save() async {
    final formValid = _formKey.currentState!.validate();
    final linesValid = _validateLines();
    if (!formValid || !linesValid) return;

    // Check all lines have a product and expiry date selected.
    for (int i = 0; i < _lines.length; i++) {
      final line = _lines[i];
      if (line.selectedProduct == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Line ${i + 1}: please select a product.'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
        return;
      }
      if (line.expiryDate == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Line ${i + 1}: please select an expiry date.'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
        return;
      }
    }

    setState(() => _isSaving = true);

    try {
      final repo = ref.read(stockInRepositoryProvider);
      // Use a placeholder userId — in a real app this comes from the auth session.
      final authService = ref.read(authServiceProvider);
      final userId = authService.currentUser?.id ?? 'unknown';

      final batches = _lines.map((line) {
        final costZmw =
            double.tryParse(line.costPriceCtrl.text.trim()) ?? 0.0;
        final costCents = (costZmw * 100).round();
        final qty = int.parse(line.quantityCtrl.text.trim());

        return StockInBatchInput(
          batchInput: BatchInput(
            productId: line.selectedProduct!.product.id,
            batchNumber: line.batchNumberCtrl.text.trim(),
            expiryDate: line.expiryDate!,
            supplierName: line.supplierCtrl.text.trim(),
            quantityReceived: qty,
            costPricePerUnit: costCents,
          ),
          quantity: qty,
        );
      }).toList();

      await repo.create(StockInCreateInput(userId: userId, batches: batches));

      // Refresh product list so updated stock levels are available.
      ref.invalidate(productRepositoryProvider);

      if (!mounted) return;

      // Build a summary of updated stock levels.
      final updatedRepo = ref.read(productRepositoryProvider);
      final productIds =
          _lines.map((l) => l.selectedProduct!.product.id).toSet();
      final allProducts = await updatedRepo.listAll();
      final updated = allProducts
          .where((ps) => productIds.contains(ps.product.id))
          .toList();

      final summary = updated
          .map((ps) => '${ps.product.name}: ${ps.stockLevel}')
          .join(', ');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Stock-in saved. Updated stock — $summary'),
            duration: const Duration(seconds: 5),
          ),
        );
        Navigator.of(context).pop();
      }
    } on ArgumentError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.message),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _resetTimer,
      child: Scaffold(
        appBar: AppBar(title: const Text('Stock-In')),
        body: Form(
          key: _formKey,
          child: Column(
            children: [
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _lines.length,
                  separatorBuilder: (_, __) => const Divider(height: 32),
                  itemBuilder: (context, index) => _BatchLineCard(
                    index: index,
                    data: _lines[index],
                    canRemove: _lines.length > 1,
                    onRemove: () => _removeLine(index),
                    onPickExpiry: () => _pickExpiry(index),
                    onChanged: _resetTimer,
                    onProductSelected: (ps) {
                      setState(() => _lines[index].selectedProduct = ps);
                      _resetTimer();
                    },
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: OutlinedButton.icon(
                  onPressed: () {
                    _addLine();
                    _resetTimer();
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('Add Another Batch'),
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                child: FilledButton(
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
                      : const Text('Save Stock-In'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _BatchLineCard — one batch entry row
// ---------------------------------------------------------------------------

class _BatchLineCard extends ConsumerStatefulWidget {
  const _BatchLineCard({
    required this.index,
    required this.data,
    required this.canRemove,
    required this.onRemove,
    required this.onPickExpiry,
    required this.onChanged,
    required this.onProductSelected,
  });

  final int index;
  final _BatchLineData data;
  final bool canRemove;
  final VoidCallback onRemove;
  final VoidCallback onPickExpiry;
  final VoidCallback onChanged;
  final void Function(ProductWithStock) onProductSelected;

  @override
  ConsumerState<_BatchLineCard> createState() => _BatchLineCardState();
}

class _BatchLineCardState extends ConsumerState<_BatchLineCard> {
  List<ProductWithStock> _suggestions = [];
  final _productSearchCtrl = TextEditingController();
  final _productFocusNode = FocusNode();
  bool _showSuggestions = false;

  @override
  void initState() {
    super.initState();
    if (widget.data.selectedProduct != null) {
      _productSearchCtrl.text = widget.data.selectedProduct!.product.name;
    }
  }

  @override
  void dispose() {
    _productSearchCtrl.dispose();
    _productFocusNode.dispose();
    super.dispose();
  }

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

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Batch ${widget.index + 1}',
                  style: theme.textTheme.titleSmall,
                ),
                const Spacer(),
                if (widget.canRemove)
                  IconButton(
                    icon: Icon(Icons.remove_circle_outline,
                        color: theme.colorScheme.error),
                    tooltip: 'Remove line',
                    onPressed: widget.onRemove,
                  ),
              ],
            ),
            const SizedBox(height: 12),

            // Product search
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  controller: _productSearchCtrl,
                  focusNode: _productFocusNode,
                  decoration: InputDecoration(
                    labelText: 'Product *',
                    border: const OutlineInputBorder(),
                    suffixIcon: data.selectedProduct != null
                        ? const Icon(Icons.check_circle, color: Colors.green)
                        : const Icon(Icons.search),
                  ),
                  validator: (_) => data.selectedProduct == null
                      ? 'Please select a product'
                      : null,
                  onChanged: (v) {
                    widget.onChanged();
                    _searchProducts(v);
                    if (data.selectedProduct != null) {
                      setState(() => data.selectedProduct = null);
                    }
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
                                '${ps.product.genericName} — stock: ${ps.stockLevel}'),
                            onTap: () {
                              widget.onProductSelected(ps);
                              _productSearchCtrl.text = ps.product.name;
                              setState(() {
                                _suggestions = [];
                                _showSuggestions = false;
                              });
                              _productFocusNode.unfocus();
                            },
                          );
                        },
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),

            // Batch number
            TextFormField(
              controller: data.batchNumberCtrl,
              decoration: const InputDecoration(
                labelText: 'Batch Number *',
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Required' : null,
              onChanged: (_) => widget.onChanged(),
            ),
            const SizedBox(height: 12),

            // Expiry date
            InkWell(
              onTap: widget.onPickExpiry,
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: 'Expiry Date *',
                  border: const OutlineInputBorder(),
                  errorText:
                      data.expiryDate == null ? null : null, // validated in _save
                  suffixIcon: const Icon(Icons.calendar_today),
                ),
                child: Text(
                  data.expiryDate != null
                      ? '${data.expiryDate!.year}-'
                          '${data.expiryDate!.month.toString().padLeft(2, '0')}-'
                          '${data.expiryDate!.day.toString().padLeft(2, '0')}'
                      : 'Select date',
                  style: data.expiryDate == null
                      ? TextStyle(color: theme.hintColor)
                      : null,
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Supplier
            TextFormField(
              controller: data.supplierCtrl,
              decoration: const InputDecoration(
                labelText: 'Supplier Name *',
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Required' : null,
              onChanged: (_) => widget.onChanged(),
            ),
            const SizedBox(height: 12),

            // Quantity
            TextFormField(
              controller: data.quantityCtrl,
              decoration: InputDecoration(
                labelText: 'Quantity *',
                border: const OutlineInputBorder(),
                errorText: data.quantityError,
              ),
              keyboardType: TextInputType.number,
              validator: (v) {
                if (v == null || v.trim().isEmpty) return 'Required';
                final n = int.tryParse(v.trim());
                if (n == null) return 'Enter a whole number';
                return null;
              },
              onChanged: (_) {
                widget.onChanged();
                if (data.quantityError != null) {
                  setState(() => data.quantityError = null);
                }
              },
            ),
            const SizedBox(height: 12),

            // Cost price
            TextFormField(
              controller: data.costPriceCtrl,
              decoration: const InputDecoration(
                labelText: 'Cost Price per Unit (ZMW) *',
                border: OutlineInputBorder(),
                prefixText: 'ZMW ',
              ),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              validator: (v) {
                if (v == null || v.trim().isEmpty) return 'Required';
                final d = double.tryParse(v.trim());
                if (d == null || d < 0) return 'Enter a valid price';
                return null;
              },
              onChanged: (_) => widget.onChanged(),
            ),
          ],
        ),
      ),
    );
  }
}
