import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pharmacy_pos/domain/entities/sale.dart';
import 'package:pharmacy_pos/domain/entities/user.dart';
import 'package:pharmacy_pos/providers/sale_provider.dart';
import 'package:pharmacy_pos/providers/session_timeout_provider.dart';

class SaleVoidScreen extends ConsumerStatefulWidget {
  const SaleVoidScreen({super.key});

  @override
  ConsumerState<SaleVoidScreen> createState() => _SaleVoidScreenState();
}

class _SaleVoidScreenState extends ConsumerState<SaleVoidScreen> {
  final _formKey = GlobalKey<FormState>();
  final _saleIdCtrl = TextEditingController();
  final _reasonCtrl = TextEditingController();

  Sale? _foundSale;
  String? _lookupError;
  String? _voidError;
  bool _isLooking = false;
  bool _isVoiding = false;

  @override
  void dispose() {
    _saleIdCtrl.dispose();
    _reasonCtrl.dispose();
    super.dispose();
  }

  void _resetTimer() => ref.read(sessionTimeoutProvider.notifier).resetTimer();

  Future<void> _lookup() async {
    final id = _saleIdCtrl.text.trim();
    if (id.isEmpty) {
      setState(() => _lookupError = 'Enter a Sale ID.');
      return;
    }
    setState(() {
      _isLooking = true;
      _lookupError = null;
      _foundSale = null;
      _voidError = null;
    });
    try {
      final repo = ref.read(saleRepositoryProvider);
      final sale = await repo.getSaleById(id);
      if (sale == null) {
        setState(() => _lookupError = 'Sale not found: $id');
      } else {
        setState(() => _foundSale = sale);
      }
    } catch (e) {
      setState(() => _lookupError = e.toString());
    } finally {
      if (mounted) setState(() => _isLooking = false);
    }
  }

  Future<void> _confirmVoid() async {
    if (!_formKey.currentState!.validate()) return;
    final sale = _foundSale;
    if (sale == null) return;

    setState(() {
      _isVoiding = true;
      _voidError = null;
    });
    try {
      final repo = ref.read(saleRepositoryProvider);
      await repo.voidSale(sale.id, _reasonCtrl.text.trim());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sale ${sale.id} voided successfully.')),
      );
      Navigator.of(context).pop();
    } on StateError catch (e) {
      setState(() => _voidError = e.message);
    } catch (e) {
      setState(() => _voidError = e.toString());
    } finally {
      if (mounted) setState(() => _isVoiding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Admin-only guard.
    final user = ref.read(authServiceProvider).currentUser;
    if (user?.role != UserRole.admin) {
      return Scaffold(
        appBar: AppBar(title: const Text('Void Sale')),
        body: const Center(
          child: Text('You do not have permission to perform this action.'),
        ),
      );
    }

    return GestureDetector(
      onTap: _resetTimer,
      child: Scaffold(
        appBar: AppBar(title: const Text('Void Sale')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Sale ID lookup
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _saleIdCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Sale ID *',
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (_) {
                            _resetTimer();
                            setState(() {
                              _foundSale = null;
                              _lookupError = null;
                              _voidError = null;
                            });
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        height: 56,
                        child: FilledButton.tonal(
                          onPressed: _isLooking
                              ? null
                              : () {
                                  _resetTimer();
                                  _lookup();
                                },
                          child: _isLooking
                              ? const SizedBox(
                                  height: 18,
                                  width: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                )
                              : const Text('Look Up'),
                        ),
                      ),
                    ],
                  ),

                  if (_lookupError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _lookupError!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error),
                      ),
                    ),

                  // Sale details card
                  if (_foundSale != null) ...[
                    const SizedBox(height: 20),
                    _SaleDetailsCard(sale: _foundSale!),
                    const SizedBox(height: 20),

                    // Reason field
                    TextFormField(
                      controller: _reasonCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Void Reason *',
                        border: OutlineInputBorder(),
                      ),
                      maxLines: 2,
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Required' : null,
                      onChanged: (_) {
                        _resetTimer();
                        if (_voidError != null) {
                          setState(() => _voidError = null);
                        }
                      },
                    ),
                    const SizedBox(height: 16),

                    if (_voidError != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          _voidError!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error),
                        ),
                      ),

                    FilledButton(
                      onPressed: (_isVoiding || _foundSale!.voided)
                          ? null
                          : () {
                              _resetTimer();
                              _confirmVoid();
                            },
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        backgroundColor:
                            Theme.of(context).colorScheme.error,
                      ),
                      child: _isVoiding
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Confirm Void'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SaleDetailsCard extends StatelessWidget {
  final Sale sale;
  const _SaleDetailsCard({required this.sale});

  @override
  Widget build(BuildContext context) {
    final total = (sale.totalZmw / 100).toStringAsFixed(2);
    final date = '${sale.recordedAt.year}-'
        '${sale.recordedAt.month.toString().padLeft(2, '0')}-'
        '${sale.recordedAt.day.toString().padLeft(2, '0')}';
    final time = '${sale.recordedAt.hour.toString().padLeft(2, '0')}:'
        '${sale.recordedAt.minute.toString().padLeft(2, '0')}';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Sale ID: ${sale.id}',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            Text('Date: $date  $time'),
            Text('Total: ZMW $total'),
            Text('Payment: ${sale.paymentMethod.name}'),
            Text('Items: ${sale.items.length}'),
            if (sale.voided)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Already voided',
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontWeight: FontWeight.bold),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
