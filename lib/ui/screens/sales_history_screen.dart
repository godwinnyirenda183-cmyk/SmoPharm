import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pharmacy_pos/domain/entities/sale.dart';
import 'package:pharmacy_pos/providers/sale_provider.dart';
import 'package:pharmacy_pos/providers/session_timeout_provider.dart';

class SalesHistoryScreen extends ConsumerStatefulWidget {
  const SalesHistoryScreen({super.key});

  @override
  ConsumerState<SalesHistoryScreen> createState() =>
      _SalesHistoryScreenState();
}

class _SalesHistoryScreenState extends ConsumerState<SalesHistoryScreen> {
  DateTime _selectedDate = DateTime.now();
  List<Sale>? _sales;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(saleRepositoryProvider);
      final sales = await repo.listByDate(_selectedDate);
      if (mounted) setState(() => _sales = sales);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() {
        _selectedDate = picked;
        _sales = null;
      });
      _load();
    }
  }

  static String _fmt(int cents) =>
      'ZMW ${(cents / 100.0).toStringAsFixed(2)}';

  static String _fmtTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}';

  static String _paymentLabel(PaymentMethod m) {
    switch (m) {
      case PaymentMethod.cash:
        return 'Cash';
      case PaymentMethod.mobileMoney:
        return 'Mobile Money';
      case PaymentMethod.insurance:
        return 'Insurance';
    }
  }

  int get _totalRevenue => (_sales ?? [])
      .where((s) => !s.voided)
      .fold(0, (sum, s) => sum + s.totalZmw);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dateLabel =
        '${_selectedDate.year}-${_selectedDate.month.toString().padLeft(2, '0')}-'
        '${_selectedDate.day.toString().padLeft(2, '0')}';

    return Scaffold(
      appBar: AppBar(title: const Text('Sales History')),
      body: Column(
        children: [
          // Date picker bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.calendar_today, size: 16),
                  label: Text(dateLabel),
                  onPressed: _pickDate,
                ),
                const SizedBox(width: 12),
                if (_sales != null)
                  Expanded(
                    child: Text(
                      '${_sales!.length} sale${_sales!.length == 1 ? '' : 's'} · '
                      'Revenue: ${_fmt(_totalRevenue)}',
                      style: theme.textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const Divider(height: 1),

          // Content
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Text(_error!,
                            style: TextStyle(
                                color: theme.colorScheme.error)))
                    : _sales == null || _sales!.isEmpty
                        ? Center(
                            child: Text(
                              'No sales on $dateLabel.',
                              style: theme.textTheme.bodyMedium
                                  ?.copyWith(color: theme.hintColor),
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.all(12),
                            itemCount: _sales!.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
                            itemBuilder: (_, i) =>
                                _SaleTile(sale: _sales![i]),
                          ),
          ),
        ],
      ),
    );
  }
}

class _SaleTile extends StatelessWidget {
  const _SaleTile({required this.sale});
  final Sale sale;

  static String _fmt(int cents) =>
      'ZMW ${(cents / 100.0).toStringAsFixed(2)}';

  static String _fmtTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}';

  static String _paymentLabel(PaymentMethod m) {
    switch (m) {
      case PaymentMethod.cash:
        return 'Cash';
      case PaymentMethod.mobileMoney:
        return 'Mobile Money';
      case PaymentMethod.insurance:
        return 'Insurance';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: ExpansionTile(
        leading: sale.voided
            ? Icon(Icons.cancel_outlined, color: theme.colorScheme.error)
            : const Icon(Icons.receipt_outlined, color: Colors.teal),
        title: Row(
          children: [
            Text(_fmtTime(sale.recordedAt),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.hintColor)),
            const SizedBox(width: 8),
            Text(_fmt(sale.totalZmw),
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            if (sale.voided) ...[
              const SizedBox(width: 8),
              Chip(
                label: const Text('VOIDED',
                    style: TextStyle(fontSize: 10)),
                backgroundColor: theme.colorScheme.errorContainer,
                labelStyle: TextStyle(
                    color: theme.colorScheme.onErrorContainer),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ],
        ),
        subtitle: Text(
          '${_paymentLabel(sale.paymentMethod)} · '
          '${sale.items.length} item${sale.items.length == 1 ? '' : 's'}',
          style: theme.textTheme.bodySmall,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Sale ID: ${sale.id}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.hintColor)),
                const SizedBox(height: 8),
                ...sale.items.map((item) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          Expanded(
                              child: Text('${item.quantity}×',
                                  style: theme.textTheme.bodySmall)),
                          Expanded(
                            flex: 4,
                            child: Text(item.productId,
                                style: theme.textTheme.bodySmall),
                          ),
                          Text(_fmt(item.lineTotal),
                              style: theme.textTheme.bodySmall),
                        ],
                      ),
                    )),
                if (sale.voided && sale.voidReason != null) ...[
                  const SizedBox(height: 8),
                  Text('Void reason: ${sale.voidReason}',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
