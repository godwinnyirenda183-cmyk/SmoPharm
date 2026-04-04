import '../entities/user.dart';

/// Represents the current session state.
enum SessionState {
  /// No user is logged in.
  unauthenticated,

  /// A user is actively logged in.
  authenticated,

  /// The session has been locked due to inactivity.
  locked,
}

/// Abstract service for authentication, session management, and account
/// lockout.
abstract class AuthService {
  /// Attempts to log in with [username] and [password].
  /// Returns the authenticated [User] on success.
  /// Throws [StateError] if the account is locked.
  /// Throws [ArgumentError] if credentials are invalid (increments failed
  /// attempts counter; locks account after 3 consecutive failures).
  Future<User> login(String username, String password);

  /// Logs out the current user and clears the session.
  Future<void> logout();

  /// Unlocks a locked account. Admin-only operation.
  /// Throws [StateError] if the caller is not an admin.
  Future<void> unlockAccount(String username);

  /// Stream of session state changes.
  Stream<SessionState> get sessionStream;

  /// Returns the currently authenticated user, or null if unauthenticated.
  User? get currentUser;
}
