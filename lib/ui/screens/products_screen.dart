import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pharmacy_pos/domain/entities/product.dart';
import 'package:pharmacy_pos/domain/entities/user.dart';
import 'package:pharmacy_pos/providers/low_stock_provider.dart';
import 'package:pharmacy_pos/providers/session_timeout_provider.dart';

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

/// Holds the current search query for the product list.
final _productSearchQueryProvider = StateProvider<String>((ref) => '');

/// Provides the filtered product list based on the search query.
final _filteredProductsProvider =
    FutureProvider<List<ProductWithStock>>((ref) async {
  final repo = ref.watch(productRepositoryProvider);
  final query = ref.watch(_productSearchQueryProvider);

  if (query.isEmpty) {
    return repo.listAll();
  }
  final matches = await repo.search(query);
  // Wrap search results with stock levels by fetching listAll and filtering.
  final all = await repo.listAll();
  final matchIds = matches.map((p) => p.id).toSet();
  return all.where((ps) => matchIds.contains(ps.product.id)).toList();
});

// ---------------------------------------------------------------------------
// ProductsScreen
// ---------------------------------------------------------------------------

class ProductsScreen extends ConsumerStatefulWidget {
  const ProductsScreen({super.key});

  @override
  ConsumerState<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends ConsumerState<ProductsScreen> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool get _isAdmin {
    final user = ref.read(authServiceProvider).currentUser;
    return user?.role == UserRole.admin;
  }

  void _resetTimer() => ref.read(sessionTimeoutProvider.notifier).resetTimer();

  Future<void> _confirmDelete(ProductWithStock ps) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Product'),
        content: Text(
          'Delete "${ps.product.name}"? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final repo = ref.read(productRepositoryProvider);
      await repo.delete(ps.product.id);
      ref.invalidate(_filteredProductsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('"${ps.product.name}" deleted.')),
        );
      }
    } on StateError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.message),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  Future<void> _openForm({ProductWithStock? existing}) async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ProductFormScreen(existing: existing?.product),
      ),
    );
    if (result == true) {
      ref.invalidate(_filteredProductsProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final productsAsync = ref.watch(_filteredProductsProvider);

    return GestureDetector(
      onTap: _resetTimer,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Products'),
        ),
        floatingActionButton: _isAdmin
            ? FloatingActionButton(
                onPressed: () {
                  _resetTimer();
                  _openForm();
                },
                tooltip: 'Add product',
                child: const Icon(Icons.add),
              )
            : null,
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'Search by name or generic name…',
                  prefixIcon: const Icon(Icons.search),
                  border: const OutlineInputBorder(),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _searchController.clear();
                            ref
                                .read(_productSearchQueryProvider.notifier)
                                .state = '';
                            _resetTimer();
                          },
                        )
                      : null,
                ),
                onChanged: (v) {
                  ref.read(_productSearchQueryProvider.notifier).state = v;
                  _resetTimer();
                },
              ),
            ),
            Expanded(
              child: productsAsync.when(
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text('Error: $e')),
                data: (products) {
                  if (products.isEmpty) {
                    return const Center(
                      child: Text('No products found.'),
                    );
                  }
                  return _ProductTable(
                    products: products,
                    isAdmin: _isAdmin,
                    onEdit: (ps) {
                      _resetTimer();
                      _openForm(existing: ps);
                    },
                    onDelete: (ps) {
                      _resetTimer();
                      _confirmDelete(ps);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Product table
// ---------------------------------------------------------------------------

class _ProductTable extends StatelessWidget {
  const _ProductTable({
    required this.products,
    required this.isAdmin,
    required this.onEdit,
    required this.onDelete,
  });

  final List<ProductWithStock> products;
  final bool isAdmin;
  final void Function(ProductWithStock) onEdit;
  final void Function(ProductWithStock) onDelete;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.vertical,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columnSpacing: 16,
          columns: const [
            DataColumn(label: Text('Name')),
            DataColumn(label: Text('Generic Name')),
            DataColumn(label: Text('Category')),
            DataColumn(label: Text('Unit')),
            DataColumn(label: Text('Price (ZMW)'), numeric: true),
            DataColumn(label: Text('Stock'), numeric: true),
            DataColumn(label: Text('Threshold'), numeric: true),
            DataColumn(label: Text('')),
          ],
          rows: products.map((ps) {
            final isLow = ps.stockLevel <= ps.product.lowStockThreshold;
            return DataRow(
              cells: [
                DataCell(Text(ps.product.name)),
                DataCell(Text(ps.product.genericName)),
                DataCell(Text(ps.product.category)),
                DataCell(Text(ps.product.unitOfMeasure)),
                DataCell(Text(
                  (ps.product.sellingPrice / 100).toStringAsFixed(2),
                )),
                DataCell(
                  Text(
                    '${ps.stockLevel}',
                    style: isLow
                        ? TextStyle(
                            color: Theme.of(context).colorScheme.error,
                            fontWeight: FontWeight.bold,
                          )
                        : null,
                  ),
                ),
                DataCell(Text('${ps.product.lowStockThreshold}')),
                DataCell(
                  isAdmin
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit, size: 18),
                              tooltip: 'Edit',
                              onPressed: () => onEdit(ps),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete, size: 18),
                              tooltip: 'Delete',
                              color: Theme.of(context).colorScheme.error,
                              onPressed: () => onDelete(ps),
                            ),
                          ],
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            );
          }).toList(),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// ProductFormScreen — create / edit
// ---------------------------------------------------------------------------

class ProductFormScreen extends ConsumerStatefulWidget {
  const ProductFormScreen({super.key, this.existing});

  /// If non-null, the form is in edit mode.
  final Product? existing;

  @override
  ConsumerState<ProductFormScreen> createState() => _ProductFormScreenState();
}

class _ProductFormScreenState extends ConsumerState<ProductFormScreen> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _nameCtrl;
  late final TextEditingController _genericNameCtrl;
  late final TextEditingController _categoryCtrl;
  late final TextEditingController _unitCtrl;
  late final TextEditingController _priceCtrl; // ZMW with 2 dp
  late final TextEditingController _thresholdCtrl;

  bool _isLoading = false;
  String? _errorMessage;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final p = widget.existing;
    _nameCtrl = TextEditingController(text: p?.name ?? '');
    _genericNameCtrl = TextEditingController(text: p?.genericName ?? '');
    _categoryCtrl = TextEditingController(text: p?.category ?? '');
    _unitCtrl = TextEditingController(text: p?.unitOfMeasure ?? '');
    _priceCtrl = TextEditingController(
      text: p != null ? (p.sellingPrice / 100).toStringAsFixed(2) : '',
    );
    _thresholdCtrl = TextEditingController(
      text: p != null ? '${p.lowStockThreshold}' : '',
    );
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _genericNameCtrl.dispose();
    _categoryCtrl.dispose();
    _unitCtrl.dispose();
    _priceCtrl.dispose();
    _thresholdCtrl.dispose();
    super.dispose();
  }

  void _resetTimer() => ref.read(sessionTimeoutProvider.notifier).resetTimer();

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    // Convert ZMW price to cents.
    final priceZmw = double.parse(_priceCtrl.text.trim());
    final priceCents = (priceZmw * 100).round();
    final threshold = int.parse(_thresholdCtrl.text.trim());

    final input = ProductInput(
      name: _nameCtrl.text.trim(),
      genericName: _genericNameCtrl.text.trim(),
      category: _categoryCtrl.text.trim(),
      unitOfMeasure: _unitCtrl.text.trim(),
      sellingPrice: priceCents,
      lowStockThreshold: threshold,
    );

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final repo = ref.read(productRepositoryProvider);
      if (_isEdit) {
        await repo.update(widget.existing!.id, input);
      } else {
        await repo.create(input);
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _errorMessage = e.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Guard: admin only.
    final user = ref.read(authServiceProvider).currentUser;
    if (user?.role != UserRole.admin) {
      return Scaffold(
        appBar: AppBar(title: Text(_isEdit ? 'Edit Product' : 'New Product')),
        body: const Center(
          child: Text('You do not have permission to perform this action.'),
        ),
      );
    }

    return GestureDetector(
      onTap: _resetTimer,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isEdit ? 'Edit Product' : 'New Product'),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _field(
                    controller: _nameCtrl,
                    label: 'Name',
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 16),
                  _field(
                    controller: _genericNameCtrl,
                    label: 'Generic Name',
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 16),
                  _field(
                    controller: _categoryCtrl,
                    label: 'Category',
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 16),
                  _field(
                    controller: _unitCtrl,
                    label: 'Unit of Measure',
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 16),
                  _field(
                    controller: _priceCtrl,
                    label: 'Selling Price (ZMW)',
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) return 'Required';
                      final d = double.tryParse(v.trim());
                      if (d == null || d < 0) {
                        return 'Enter a valid price (e.g. 12.50)';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  _field(
                    controller: _thresholdCtrl,
                    label: 'Low Stock Threshold',
                    keyboardType: TextInputType.number,
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) return 'Required';
                      final n = int.tryParse(v.trim());
                      if (n == null || n < 0) {
                        return 'Enter a non-negative integer';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 24),
                  if (_errorMessage != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        _errorMessage!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  FilledButton(
                    onPressed: _isLoading
                        ? null
                        : () {
                            _resetTimer();
                            _save();
                          },
                    child: _isLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(_isEdit ? 'Save Changes' : 'Create Product'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      keyboardType: keyboardType,
      validator: validator,
      onChanged: (_) => _resetTimer(),
    );
  }
}
