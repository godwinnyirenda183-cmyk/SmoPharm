import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pharmacy_pos/domain/entities/sale.dart';
import 'package:pharmacy_pos/domain/entities/user.dart';
import 'package:pharmacy_pos/domain/services/report_service.dart';
import 'package:pharmacy_pos/providers/report_provider.dart';
import 'package:pharmacy_pos/providers/session_timeout_provider.dart';

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // Daily sales state
  DateTime _selectedDate = DateTime.now();
  DailySalesReport? _dailyReport;
  bool _dailyLoading = false;
  String? _dailyError;

  // Inventory state
  List<InventoryReportRow>? _inventoryRows;
  bool _inventoryLoading = false;
  String? _inventoryError;

  // Low stock state
  List<LowStockReportRow>? _lowStockRows;
  bool _lowStockLoading = false;
  String? _lowStockError;

  // Near expiry state
  List<NearExpiryReportRow>? _nearExpiryRows;
  bool _nearExpiryLoading = false;
  String? _nearExpiryError;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) _loadCurrentTab();
    });
    // Load first tab on open
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadDailySales());
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _resetTimer() => ref.read(sessionTimeoutProvider.notifier).resetTimer();

  void _loadCurrentTab() {
    switch (_tabController.index) {
      case 0:
        _loadDailySales();
        break;
      case 1:
        _loadInventory();
        break;
      case 2:
        _loadLowStock();
        break;
      case 3:
        _loadNearExpiry();
        break;
    }
  }

  Future<void> _loadDailySales() async {
    setState(() {
      _dailyLoading = true;
      _dailyError = null;
    });
    try {
      final svc = ref.read(reportServiceProvider);
      final report = await svc.dailySalesReport(_selectedDate);
      if (mounted) setState(() => _dailyReport = report);
    } catch (e) {
      if (mounted) setState(() => _dailyError = e.toString());
    } finally {
      if (mounted) setState(() => _dailyLoading = false);
    }
  }

  Future<void> _loadInventory() async {
    if (_inventoryRows != null) return;
    setState(() {
      _inventoryLoading = true;
      _inventoryError = null;
    });
    try {
      final svc = ref.read(reportServiceProvider);
      final rows = await svc.inventoryReport();
      if (mounted) setState(() => _inventoryRows = rows);
    } catch (e) {
      if (mounted) setState(() => _inventoryError = e.toString());
    } finally {
      if (mounted) setState(() => _inventoryLoading = false);
    }
  }

  Future<void> _loadLowStock() async {
    if (_lowStockRows != null) return;
    setState(() {
      _lowStockLoading = true;
      _lowStockError = null;
    });
    try {
      final svc = ref.read(reportServiceProvider);
      final rows = await svc.lowStockReport();
      if (mounted) setState(() => _lowStockRows = rows);
    } catch (e) {
      if (mounted) setState(() => _lowStockError = e.toString());
    } finally {
      if (mounted) setState(() => _lowStockLoading = false);
    }
  }

  Future<void> _loadNearExpiry() async {
    if (_nearExpiryRows != null) return;
    setState(() {
      _nearExpiryLoading = true;
      _nearExpiryError = null;
    });
    try {
      final svc = ref.read(reportServiceProvider);
      final rows = await svc.nearExpiryReport();
      if (mounted) setState(() => _nearExpiryRows = rows);
    } catch (e) {
      if (mounted) setState(() => _nearExpiryError = e.toString());
    } finally {
      if (mounted) setState(() => _nearExpiryLoading = false);
    }
  }

  Future<void> _exportCsv<T>(List<T> rows, String filename) async {
    try {
      final svc = ref.read(reportServiceProvider);
      final csv = await svc.exportCsv(rows);
      // Write to the system temp directory (works on both Android and Windows).
      final dir = Directory.systemTemp;
      final file = File('${dir.path}/$filename');
      await file.writeAsString(csv);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Exported to ${file.path}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    }
  }

  String _centsToZmw(int cents) => 'ZMW ${(cents / 100).toStringAsFixed(2)}';

  String _paymentLabel(PaymentMethod m) {
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
    final user = ref.read(authServiceProvider).currentUser;
    if (user?.role != UserRole.admin) {
      return Scaffold(
        appBar: AppBar(title: const Text('Reports')),
        body: const Center(
          child: Text('You do not have permission to perform this action.'),
        ),
      );
    }

    return GestureDetector(
      onTap: _resetTimer,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Reports'),
          bottom: TabBar(
            controller: _tabController,
            tabs: const [
              Tab(text: 'Daily Sales'),
              Tab(text: 'Inventory'),
              Tab(text: 'Low Stock'),
              Tab(text: 'Near Expiry'),
            ],
          ),
        ),
        body: TabBarView(
          controller: _tabController,
          children: [
            _buildDailySalesTab(),
            _buildInventoryTab(),
            _buildLowStockTab(),
            _buildNearExpiryTab(),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Daily Sales Tab
  // ---------------------------------------------------------------------------

  Widget _buildDailySalesTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Date:', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.calendar_today, size: 16),
                label: Text(
                  '${_selectedDate.year}-'
                  '${_selectedDate.month.toString().padLeft(2, '0')}-'
                  '${_selectedDate.day.toString().padLeft(2, '0')}',
                ),
                onPressed: () async {
                  _resetTimer();
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _selectedDate,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now(),
                  );
                  if (picked != null) {
                    setState(() {
                      _selectedDate = picked;
                      _dailyReport = null;
                    });
                    _loadDailySales();
                  }
                },
              ),
              const SizedBox(width: 12),
              if (_dailyReport != null)
                OutlinedButton.icon(
                  icon: const Icon(Icons.download, size: 16),
                  label: const Text('Export CSV'),
                  onPressed: () {
                    _resetTimer();
                    _exportCsv(
                      [_dailyReport!],
                      'daily_sales_${_selectedDate.toIso8601String().substring(0, 10)}.csv',
                    );
                  },
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (_dailyLoading)
            const Center(child: CircularProgressIndicator())
          else if (_dailyError != null)
            Text(_dailyError!, style: const TextStyle(color: Colors.red))
          else if (_dailyReport != null)
            _buildDailySalesContent(_dailyReport!),
        ],
      ),
    );
  }

  Widget _buildDailySalesContent(DailySalesReport report) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Total Revenue: ${_centsToZmw(report.totalRevenueCents)}',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text('Transactions: ${report.transactionCount}'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        const Text('Breakdown by Payment Method',
            style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        ...report.revenueByPaymentMethod.entries.map((e) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  SizedBox(width: 160, child: Text(_paymentLabel(e.key))),
                  Text(_centsToZmw(e.value)),
                ],
              ),
            )),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Inventory Tab
  // ---------------------------------------------------------------------------

  Widget _buildInventoryTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Refresh'),
                onPressed: () {
                  _resetTimer();
                  setState(() => _inventoryRows = null);
                  _loadInventory();
                },
              ),
              const SizedBox(width: 8),
              if (_inventoryRows != null)
                OutlinedButton.icon(
                  icon: const Icon(Icons.download, size: 16),
                  label: const Text('Export CSV'),
                  onPressed: () {
                    _resetTimer();
                    _exportCsv(_inventoryRows!, 'inventory_report.csv');
                  },
                ),
            ],
          ),
        ),
        if (_inventoryLoading)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (_inventoryError != null)
          Expanded(
            child: Center(
              child: Text(_inventoryError!,
                  style: const TextStyle(color: Colors.red)),
            ),
          )
        else if (_inventoryRows != null)
          Expanded(child: _buildInventoryTable(_inventoryRows!))
        else
          const Expanded(child: Center(child: Text('No data'))),
      ],
    );
  }

  Widget _buildInventoryTable(List<InventoryReportRow> rows) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SingleChildScrollView(
        child: DataTable(
          columns: const [
            DataColumn(label: Text('Product')),
            DataColumn(label: Text('Generic Name')),
            DataColumn(label: Text('Category')),
            DataColumn(label: Text('Unit')),
            DataColumn(label: Text('Stock'), numeric: true),
            DataColumn(label: Text('Unit Cost'), numeric: true),
            DataColumn(label: Text('Total Value'), numeric: true),
          ],
          rows: rows
              .map((r) => DataRow(cells: [
                    DataCell(Text(r.product.name)),
                    DataCell(Text(r.product.genericName)),
                    DataCell(Text(r.product.category)),
                    DataCell(Text(r.product.unitOfMeasure)),
                    DataCell(Text('${r.stockLevel}')),
                    DataCell(Text(_centsToZmw(r.unitCostCents))),
                    DataCell(Text(_centsToZmw(r.totalValueCents))),
                  ]))
              .toList(),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Low Stock Tab
  // ---------------------------------------------------------------------------

  Widget _buildLowStockTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Refresh'),
                onPressed: () {
                  _resetTimer();
                  setState(() => _lowStockRows = null);
                  _loadLowStock();
                },
              ),
              const SizedBox(width: 8),
              if (_lowStockRows != null)
                OutlinedButton.icon(
                  icon: const Icon(Icons.download, size: 16),
                  label: const Text('Export CSV'),
                  onPressed: () {
                    _resetTimer();
                    _exportCsv(_lowStockRows!, 'low_stock_report.csv');
                  },
                ),
            ],
          ),
        ),
        if (_lowStockLoading)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (_lowStockError != null)
          Expanded(
            child: Center(
              child: Text(_lowStockError!,
                  style: const TextStyle(color: Colors.red)),
            ),
          )
        else if (_lowStockRows != null)
          Expanded(child: _buildLowStockTable(_lowStockRows!))
        else
          const Expanded(child: Center(child: Text('No data'))),
      ],
    );
  }

  Widget _buildLowStockTable(List<LowStockReportRow> rows) {
    if (rows.isEmpty) {
      return const Center(child: Text('No low-stock products.'));
    }
    return SingleChildScrollView(
      child: DataTable(
        columns: const [
          DataColumn(label: Text('Product')),
          DataColumn(label: Text('Generic Name')),
          DataColumn(label: Text('Stock Level'), numeric: true),
          DataColumn(label: Text('Threshold'), numeric: true),
        ],
        rows: rows
            .map((r) => DataRow(cells: [
                  DataCell(Text(r.product.name)),
                  DataCell(Text(r.product.genericName)),
                  DataCell(Text('${r.stockLevel}')),
                  DataCell(Text('${r.lowStockThreshold}')),
                ]))
            .toList(),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Near Expiry Tab
  // ---------------------------------------------------------------------------

  Widget _buildNearExpiryTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Refresh'),
                onPressed: () {
                  _resetTimer();
                  setState(() => _nearExpiryRows = null);
                  _loadNearExpiry();
                },
              ),
              const SizedBox(width: 8),
              if (_nearExpiryRows != null)
                OutlinedButton.icon(
                  icon: const Icon(Icons.download, size: 16),
                  label: const Text('Export CSV'),
                  onPressed: () {
                    _resetTimer();
                    _exportCsv(_nearExpiryRows!, 'near_expiry_report.csv');
                  },
                ),
            ],
          ),
        ),
        if (_nearExpiryLoading)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (_nearExpiryError != null)
          Expanded(
            child: Center(
              child: Text(_nearExpiryError!,
                  style: const TextStyle(color: Colors.red)),
            ),
          )
        else if (_nearExpiryRows != null)
          Expanded(child: _buildNearExpiryTable(_nearExpiryRows!))
        else
          const Expanded(child: Center(child: Text('No data'))),
      ],
    );
  }

  Widget _buildNearExpiryTable(List<NearExpiryReportRow> rows) {
    if (rows.isEmpty) {
      return const Center(child: Text('No near-expiry batches.'));
    }
    return SingleChildScrollView(
      child: DataTable(
        columns: const [
          DataColumn(label: Text('Product')),
          DataColumn(label: Text('Batch Number')),
          DataColumn(label: Text('Expiry Date')),
          DataColumn(label: Text('Qty Remaining'), numeric: true),
        ],
        rows: rows
            .map((r) => DataRow(cells: [
                  DataCell(Text(r.product.name)),
                  DataCell(Text(r.batch.batchNumber)),
                  DataCell(Text(
                    r.batch.expiryDate.toIso8601String().substring(0, 10),
                  )),
                  DataCell(Text('${r.batch.quantityRemaining}')),
                ]))
            .toList(),
      ),
    );
  }
}
