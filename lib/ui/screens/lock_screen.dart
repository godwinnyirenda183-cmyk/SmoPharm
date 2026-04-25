import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pharmacy_pos/providers/session_timeout_provider.dart';

/// Shown when the session has been locked due to inactivity.
///
/// The user must re-enter their password to resume. On success the app
/// navigates back to the dashboard without losing any navigation history.
class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  final _passwordCtrl = TextEditingController();
  bool _isLoading = false;
  String? _error;
  bool _obscure = true;

  @override
  void dispose() {
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    final password = _passwordCtrl.text;
    if (password.isEmpty) {
      setState(() => _error = 'Enter your password to unlock.');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final authService = ref.read(authServiceProvider);
      final currentUser = authService.currentUser;

      // currentUser may be null after logout — fall back to re-login flow.
      if (currentUser == null) {
        if (mounted) {
          Navigator.of(context)
              .pushNamedAndRemoveUntil('/', (route) => false);
        }
        return;
      }

      // Re-authenticate with the same username.
      await authService.login(currentUser.username, password);

      // Reset the inactivity timer now that the session is restored.
      ref.read(sessionTimeoutProvider.notifier).resetTimer();

      if (mounted) Navigator.of(context).pop();
    } on StateError catch (e) {
      setState(() => _error = e.message);
    } on ArgumentError {
      setState(() => _error = 'Incorrect password.');
    } catch (_) {
      setState(() => _error = 'An unexpected error occurred.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final authService = ref.read(authServiceProvider);
    final username = authService.currentUser?.username ?? 'user';

    return PopScope(
      // Prevent back-navigation — the user must unlock.
      canPop: false,
      child: Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.lock_outline, size: 64, color: Colors.teal),
                  const SizedBox(height: 16),
                  Text(
                    'Session Locked',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Locked due to inactivity.\nEnter your password to continue as $username.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: Theme.of(context).hintColor),
                  ),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _passwordCtrl,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                        onPressed: () =>
                            setState(() => _obscure = !_obscure),
                      ),
                    ),
                    obscureText: _obscure,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _unlock(),
                    enabled: !_isLoading,
                    autofocus: true,
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _isLoading ? null : _unlock,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Unlock'),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _isLoading
                        ? null
                        : () async {
                            final authService =
                                ref.read(authServiceProvider);
                            await authService.logout();
                            if (mounted) {
                              Navigator.of(context).pushNamedAndRemoveUntil(
                                  '/', (route) => false);
                            }
                          },
                    child: const Text('Sign in as a different user'),
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
