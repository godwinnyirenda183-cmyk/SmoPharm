import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pharmacy_pos/domain/entities/user.dart';
import 'package:pharmacy_pos/providers/session_timeout_provider.dart';
import 'package:pharmacy_pos/providers/settings_provider.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _windowCtrl = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  String? _inlineError;

  void _resetTimer() => ref.read(sessionTimeoutProvider.notifier).resetTimer();

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final repo = ref.read(settingsRepositoryProvider);
    final name = await repo.getPharmacyName();
    final address = await repo.getPharmacyAddress();
    final phone = await repo.getPharmacyPhone();
    final window = await repo.getNearExpiryWindowDays();
    if (!mounted) return;
    setState(() {
      _nameCtrl.text = name;
      _addressCtrl.text = address;
      _phoneCtrl.text = phone;
      _windowCtrl.text = window.toString();
      _loading = false;
    });
  }

  Future<void> _save() async {
    setState(() => _inlineError = null);
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);
    try {
      final repo = ref.read(settingsRepositoryProvider);
      await repo.setPharmacyName(_nameCtrl.text.trim());
      await repo.setPharmacyAddress(_addressCtrl.text.trim());
      await repo.setPharmacyPhone(_phoneCtrl.text.trim());
      await repo.setNearExpiryWindowDays(int.parse(_windowCtrl.text.trim()));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings saved successfully.')),
      );
    } on ArgumentError catch (e) {
      setState(() => _inlineError = e.message);
    } catch (e) {
      setState(() => _inlineError = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _addressCtrl.dispose();
    _phoneCtrl.dispose();
    _windowCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Admin-only guard.
    final user = ref.read(authServiceProvider).currentUser;
    if (user?.role != UserRole.admin) {
      return Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: const Center(
          child: Text('You do not have permission to perform this action.'),
        ),
      );
    }

    return GestureDetector(
      onTap: _resetTimer,
      child: Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextFormField(
                          controller: _nameCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Pharmacy Name',
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (_) => _resetTimer(),
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _addressCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Address',
                            border: OutlineInputBorder(),
                          ),
                          maxLines: 2,
                          onChanged: (_) => _resetTimer(),
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _phoneCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Phone',
                            border: OutlineInputBorder(),
                          ),
                          keyboardType: TextInputType.phone,
                          onChanged: (_) => _resetTimer(),
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _windowCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Near-Expiry Window (days)',
                            helperText: 'Must be between 1 and 365',
                            border: OutlineInputBorder(),
                          ),
                          keyboardType: TextInputType.number,
                          validator: (v) {
                            if (v == null || v.trim().isEmpty) {
                              return 'Required';
                            }
                            final n = int.tryParse(v.trim());
                            if (n == null) return 'Enter a whole number';
                            if (n < 1 || n > 365) {
                              return 'Near-expiry window must be between 1 and 365 days';
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
                        const SizedBox(height: 24),
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
                          onPressed: _saving
                              ? null
                              : () {
                                  _save();
                                },
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(48),
                          ),
                          child: _saving
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                )
                              : const Text('Save Settings'),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: () =>
                              Navigator.of(context).pushNamed('/change-password'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(48),
                          ),
                          child: const Text('Change Password'),
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
