import 'package:bcrypt/bcrypt.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pharmacy_pos/database/database.dart';
import 'package:pharmacy_pos/domain/entities/user.dart';
import 'package:pharmacy_pos/providers/database_provider.dart';
import 'package:pharmacy_pos/providers/session_timeout_provider.dart';
import 'package:uuid/uuid.dart';

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

final _usersProvider = FutureProvider<List<UserRow>>((ref) async {
  final db = ref.watch(databaseProvider);
  return db.select(db.users).get();
});

// ---------------------------------------------------------------------------
// UserManagementScreen
// ---------------------------------------------------------------------------

/// Admin-only screen for creating cashier accounts and unlocking locked users.
class UserManagementScreen extends ConsumerWidget {
  const UserManagementScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Admin-only guard.
    final user = ref.read(authServiceProvider).currentUser;
    if (user?.role != UserRole.admin) {
      return Scaffold(
        appBar: AppBar(title: const Text('User Management')),
        body: const Center(
          child: Text('You do not have permission to perform this action.'),
        ),
      );
    }

    final usersAsync = ref.watch(_usersProvider);

    return GestureDetector(
      onTap: () => ref.read(sessionTimeoutProvider.notifier).resetTimer(),
      child: Scaffold(
        appBar: AppBar(title: const Text('User Management')),
        floatingActionButton: FloatingActionButton(
          onPressed: () async {
            ref.read(sessionTimeoutProvider.notifier).resetTimer();
            final created = await Navigator.of(context).push<bool>(
              MaterialPageRoute(
                builder: (_) => const _CreateUserScreen(),
              ),
            );
            if (created == true) ref.invalidate(_usersProvider);
          },
          tooltip: 'Add user',
          child: const Icon(Icons.person_add),
        ),
        body: usersAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Error: $e')),
          data: (users) {
            if (users.isEmpty) {
              return const Center(child: Text('No users found.'));
            }
            return ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: users.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) => _UserTile(
                user: users[i],
                onUnlock: () async {
                  ref.read(sessionTimeoutProvider.notifier).resetTimer();
                  final db = ref.read(databaseProvider);
                  await (db.update(db.users)
                        ..where((u) => u.id.equals(users[i].id)))
                      .write(const UsersCompanion(
                    locked: Value(false),
                    failedAttempts: Value(0),
                  ));
                  ref.invalidate(_usersProvider);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                            '${users[i].username} unlocked.'),
                      ),
                    );
                  }
                },
                onDelete: users[i].role == 'admin'
                    ? null // prevent deleting admin accounts
                    : () async {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Delete User'),
                            content: Text(
                              'Delete "${users[i].username}"?',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.of(ctx).pop(false),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                style: FilledButton.styleFrom(
                                  backgroundColor:
                                      Theme.of(ctx).colorScheme.error,
                                ),
                                onPressed: () =>
                                    Navigator.of(ctx).pop(true),
                                child: const Text('Delete'),
                              ),
                            ],
                          ),
                        );
                        if (confirmed != true) return;
                        final db = ref.read(databaseProvider);
                        await (db.delete(db.users)
                              ..where((u) => u.id.equals(users[i].id)))
                            .go();
                        ref.invalidate(_usersProvider);
                      },
              ),
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _UserTile
// ---------------------------------------------------------------------------

class _UserTile extends StatelessWidget {
  const _UserTile({
    required this.user,
    required this.onUnlock,
    required this.onDelete,
  });

  final UserRow user;
  final VoidCallback onUnlock;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
        child: Text(user.username[0].toUpperCase()),
      ),
      title: Text(user.username),
      subtitle: Text(
        '${user.role.toUpperCase()}'
        '${user.locked ? ' · LOCKED' : ''}',
        style: TextStyle(
          color: user.locked ? Theme.of(context).colorScheme.error : null,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (user.locked)
            IconButton(
              icon: const Icon(Icons.lock_open),
              tooltip: 'Unlock account',
              onPressed: onUnlock,
            ),
          if (onDelete != null)
            IconButton(
              icon: Icon(Icons.delete_outline,
                  color: Theme.of(context).colorScheme.error),
              tooltip: 'Delete user',
              onPressed: onDelete,
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _CreateUserScreen
// ---------------------------------------------------------------------------

class _CreateUserScreen extends ConsumerStatefulWidget {
  const _CreateUserScreen();

  @override
  ConsumerState<_CreateUserScreen> createState() => _CreateUserScreenState();
}

class _CreateUserScreenState extends ConsumerState<_CreateUserScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  UserRole _role = UserRole.cashier;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  bool _isSaving = false;
  String? _error;

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _error = null);
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSaving = true);
    try {
      final db = ref.read(databaseProvider);

      // Check username uniqueness.
      final existing = await (db.select(db.users)
            ..where((u) => u.username.equals(_usernameCtrl.text.trim())))
          .getSingleOrNull();
      if (existing != null) {
        setState(() => _error = 'Username already exists.');
        return;
      }

      final hash = BCrypt.hashpw(
        _passwordCtrl.text,
        BCrypt.gensalt(logRounds: 12),
      );

      await db.into(db.users).insert(
            UsersCompanion.insert(
              id: const Uuid().v4(),
              username: _usernameCtrl.text.trim(),
              passwordHash: hash,
              role: _role == UserRole.admin ? 'admin' : 'cashier',
            ),
          );

      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New User')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _usernameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Username',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<UserRole>(
                  value: _role,
                  decoration: const InputDecoration(
                    labelText: 'Role',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: UserRole.cashier,
                      child: Text('Cashier'),
                    ),
                    DropdownMenuItem(
                      value: UserRole.admin,
                      child: Text('Admin'),
                    ),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _role = v);
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _passwordCtrl,
                  obscureText: _obscurePassword,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(_obscurePassword
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined),
                      onPressed: () => setState(
                          () => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                  validator: (v) {
                    if (v == null || v.isEmpty) return 'Required';
                    if (v.length < 8) {
                      return 'At least 8 characters';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _confirmCtrl,
                  obscureText: _obscureConfirm,
                  decoration: InputDecoration(
                    labelText: 'Confirm Password',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(_obscureConfirm
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined),
                      onPressed: () => setState(
                          () => _obscureConfirm = !_obscureConfirm),
                    ),
                  ),
                  validator: (v) {
                    if (v == null || v.isEmpty) return 'Required';
                    if (v != _passwordCtrl.text) {
                      return 'Passwords do not match';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 24),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                FilledButton(
                  onPressed: _isSaving ? null : _save,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  child: _isSaving
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Create User'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
