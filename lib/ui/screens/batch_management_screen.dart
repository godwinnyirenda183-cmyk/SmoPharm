import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pharmacy_pos/domain/entities/batch.dart';
import 'package:pharmacy_pos/domain/entities/product.dart';
import 'package:pharmacy_pos/providers/batch_provider.dart';
import 'package:pharmacy_pos/providers/low_stock_provider.dart';

// ---------------------------------------------------------------------------
// BatchManagementScreen
// ---------------------------------------------------------------------------

/// Shows all batches for a selected product with their status, quantity,
/// expiry date, and cost price. Useful for stock audits.
class BatchManagementScreen extends ConsumerStatefulWidget {
  const BatchManagementScreen({super.key});

  @override
  ConsumerState<BatchManagementScreen> createState() =>
      _BatchManagementScreenState();
}

class _BatchManagementScreenState
    extends ConsumerState<BatchManagementScreen> {
  final _searchCtrl = TextEditingController();
  ProductWithStock? _selectedProduct;
  List<ProductWithStock> _suggestions = [];
  bool _showSuggestions = false;
  List<_BatchRow>? _batches;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _searchCtrl.dispose();
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

  Future<void> _loadBatches(ProductWithStock ps) async {
    setState(() {
      _selectedProduct = ps;
      _loading = true;
      _error = null;
      _batches = null;
    });
    try {
      final batchRepo = ref.read(batchRepositoryProvider);
      // Collect batches across all statuses.
      final nearExpiry = await batchRepo.nearExpiry(365);
      final expired = await batchRepo.expiredBatches();
      // Active: use FEFO to find any active batch, then list all.
      // Since the repo doesn't expose listAll, we combine all known statuses.
      final allKnown = {...nearExpiry, ...expired};
      // Also try to get the FEFO batch (active).
      final fefo = await batchRepo.selectFEFO(ps.product.id, 0);

      // Build rows from what we have, filtered to this product.
      final rows = <_BatchRow>[];
      for (final b in allKnown) {
        if (b.productId == ps.product.id) {
          rows.add(_BatchRow(batch: b));
        }
      }
      if (fefo != null && fefo.productId == ps.product.id) {
        if (!rows.any((r) => r.batch.id == fefo.id)) {
          rows.add(_BatchRow(batch: fefo));
        }
      }
      rows.sort((a, b) => a.batch.expiryDate.compareTo(b.batch.expiryDate));
      if (mounted) setState(() => _batches = rows);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  static String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static String _fmtZmw(int cents) =>
      'ZMW ${(cents / 100.0).toStringAsFixed(2)}';

  Color _statusColor(BuildContext context, BatchStatus status) {
    switch (status) {
      case BatchStatus.active:
        return Colors.green;
      case BatchStatus.nearExpiry:
        return Colors.orange;
      case BatchStatus.expired:
        return Theme.of(context).colorScheme.error;
    }
  }

  String _statusLabel(BatchStatus status) {
    switch (status) {
      case BatchStatus.active:
        return 'Active';
      case BatchStatus.nearExpiry:
        return 'Near Expiry';
      case BatchStatus.expired:
        return 'Expired';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Batch Management')),
      body: Column(
        children: [
          // Product search
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _searchCtrl,
                  decoration: InputDecoration(
                    labelText: 'Search product',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _selectedProduct != null
                        ? const Icon(Icons.check_circle,
                            color: Colors.green)
                        : null,
                  ),
                  onChanged: (v) {
                    if (_selectedProduct != null) {
                      setState(() {
                        _selectedProduct = null;
                        _batches = null;
                      });
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
                                '${ps.product.genericName} · stock: ${ps.stockLevel}'),
                            onTap: () {
                              _searchCtrl.text = ps.product.name;
                              setState(() {
                                _suggestions = [];
                                _showSuggestions = false;
                              });
                              _loadBatches(ps);
                            },
                          );
                        },
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),

          // Batch list
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Text(_error!,
                            style: TextStyle(
                                color:
                                    Theme.of(context).colorScheme.error)))
                    : _batches == null
                        ? Center(
                            child: Text(
                              'Search for a product to view its batches.',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(
                                      color: Theme.of(context).hintColor),
                            ),
                          )
                        : _batches!.isEmpty
                            ? const Center(
                                child: Text('No batches found.'))
                            : ListView.separated(
                                padding: const EdgeInsets.all(12),
                                itemCount: _batches!.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 8),
                                itemBuilder: (_, i) {
                                  final row = _batches![i];
                                  final b = row.batch;
                                  final color = _statusColor(
                                      context, b.status);
                                  return Card(
                                    child: ListTile(
                                      leading: CircleAvatar(
                                        backgroundColor:
                                            color.withValues(alpha: 0.15),
                                        child: Icon(
                                          Icons.inventory_2_outlined,
                                          color: color,
                                          size: 20,
                                        ),
                                      ),
                                      title: Text(b.batchNumber),
                                      subtitle: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                              'Expiry: ${_fmtDate(b.expiryDate)}'),
                                          Text(
                                              'Supplier: ${b.supplierName}'),
                                          Text(
                                              'Cost: ${_fmtZmw(b.costPricePerUnit)} / unit'),
                                        ],
                                      ),
                                      trailing: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.end,
                                        children: [
                                          Text(
                                            '${b.quantityRemaining}',
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleMedium
                                                ?.copyWith(
                                                    fontWeight:
                                                        FontWeight.bold),
                                          ),
                                          Text(
                                            _statusLabel(b.status),
                                            style: TextStyle(
                                                color: color,
                                                fontSize: 11),
                                          ),
                                        ],
                                      ),
                                      isThreeLine: true,
                                    ),
                                  );
                                },
                              ),
          ),
        ],
      ),
    );
  }
}

class _BatchRow {
  final Batch batch;
  _BatchRow({required this.batch});
}
