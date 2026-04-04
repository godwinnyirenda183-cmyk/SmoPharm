/// User roles in the system.
enum UserRole { admin, cashier }

/// Domain entity for an authenticated system user.
class User {
  final String id;
  final String username;
  final String passwordHash;
  final UserRole role;
  final bool locked;
  final int failedAttempts;
  final DateTime createdAt;

  const User({
    required this.id,
    required this.username,
    required this.passwordHash,
    required this.role,
    required this.locked,
    required this.failedAttempts,
    required this.createdAt,
  });
}
