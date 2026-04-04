import 'dart:async';

import 'package:bcrypt/bcrypt.dart';
import 'package:drift/drift.dart';
import 'package:pharmacy_pos/database/database.dart';
import 'package:pharmacy_pos/domain/entities/user.dart';
import 'package:pharmacy_pos/domain/services/auth_service.dart';

/// Thrown when an operation requires admin privileges but the caller is not
/// an admin.
class UnauthorizedException implements Exception {
  final String message;
  const UnauthorizedException([this.message = 'Unauthorized']);

  @override
  String toString() => 'UnauthorizedException: $message';
}

/// Concrete implementation of [AuthService] backed by the Drift [AppDatabase].
///
/// Password hashing uses bcrypt with cost factor 12.
/// Account lockout occurs after 3 consecutive failed login attempts.
class AuthServiceImpl implements AuthService {
  final AppDatabase _db;

  User? _currentUser;
  final StreamController<SessionState> _sessionController =
      StreamController<SessionState>.broadcast();

  AuthServiceImpl(this._db);

  // ---------------------------------------------------------------------------
  // AuthService interface
  // ---------------------------------------------------------------------------

  @override
  User? get currentUser => _currentUser;

  @override
  Stream<SessionState> get sessionStream => _sessionController.stream;

  /// Attempts to log in with [username] and [password].
  ///
  /// - Throws [StateError] with "Account locked. Contact your administrator."
  ///   if the account is locked.
  /// - Throws [ArgumentError] with "Invalid username or password" if the
  ///   username does not exist or the password is wrong.
  /// - Increments `failed_attempts` on each wrong password.
  /// - Locks the account (sets `locked = true`) after 3 consecutive failures.
  @override
  Future<User> login(String username, String password) async {
    final row = await _fetchUserRow(username);

    if (row == null) {
      // Username not found — do not reveal which field is wrong.
      throw ArgumentError('Invalid username or password');
    }

    if (row.locked) {
      throw StateError('Account locked. Contact your administrator.');
    }

    final passwordMatches = BCrypt.checkpw(password, row.passwordHash);

    if (!passwordMatches) {
      final newFailedAttempts = row.failedAttempts + 1;
      final shouldLock = newFailedAttempts >= 3;

      await (_db.update(_db.users)..where((u) => u.id.equals(row.id))).write(
        UsersCompanion(
          failedAttempts: Value(newFailedAttempts),
          locked: Value(shouldLock),
        ),
      );

      if (shouldLock) {
        throw StateError('Account locked. Contact your administrator.');
      }

      throw ArgumentError('Invalid username or password');
    }

    // Successful login — reset failed attempts counter.
    await (_db.update(_db.users)..where((u) => u.id.equals(row.id))).write(
      const UsersCompanion(failedAttempts: Value(0)),
    );

    _currentUser = _rowToEntity(row.copyWith(failedAttempts: 0));
    _sessionController.add(SessionState.authenticated);
    return _currentUser!;
  }

  /// Logs out the current user and clears the session.
  @override
  Future<void> logout() async {
    _currentUser = null;
    _sessionController.add(SessionState.unauthenticated);
  }

  /// Unlocks a locked account identified by [username].
  ///
  /// - Throws [UnauthorizedException] if the currently authenticated user is
  ///   not an admin.
  /// - Resets `failed_attempts` to 0 and `locked` to false.
  @override
  Future<void> unlockAccount(String username) async {
    if (_currentUser == null || _currentUser!.role != UserRole.admin) {
      throw const UnauthorizedException(
          'Only an admin can unlock user accounts.');
    }

    final row = await _fetchUserRow(username);
    if (row == null) {
      throw ArgumentError('User not found: $username');
    }

    await (_db.update(_db.users)..where((u) => u.id.equals(row.id))).write(
      const UsersCompanion(
        failedAttempts: Value(0),
        locked: Value(false),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Future<UserRow?> _fetchUserRow(String username) async {
    return (_db.select(_db.users)
          ..where((u) => u.username.equals(username)))
        .getSingleOrNull();
  }

  User _rowToEntity(UserRow row) {
    return User(
      id: row.id,
      username: row.username,
      passwordHash: row.passwordHash,
      role: row.role == 'admin' ? UserRole.admin : UserRole.cashier,
      locked: row.locked,
      failedAttempts: row.failedAttempts,
      createdAt: row.createdAt,
    );
  }

  // ---------------------------------------------------------------------------
  // Utility — exposed for seeding / testing
  // ---------------------------------------------------------------------------

  /// Hashes [plainPassword] using bcrypt with cost factor 12.
  static String hashPassword(String plainPassword) {
    return BCrypt.hashpw(plainPassword, BCrypt.gensalt(logRounds: 12));
  }
}
