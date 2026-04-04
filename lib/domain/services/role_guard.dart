import 'package:pharmacy_pos/data/services/auth_service_impl.dart';
import 'package:pharmacy_pos/domain/entities/user.dart';

/// Thrown when an operation requires authentication but no user is logged in.
class UnauthenticatedException implements Exception {
  final String message;
  const UnauthenticatedException(
      [this.message = 'Authentication required. Please log in.']);

  @override
  String toString() => 'UnauthenticatedException: $message';
}

/// Asserts that [currentUser] is an admin.
///
/// Throws [UnauthorizedException] with the standard permission-denied message
/// if [currentUser] is null or has the cashier role.
void requireAdmin(User? currentUser) {
  if (currentUser == null || currentUser.role != UserRole.admin) {
    throw const UnauthorizedException(
        'You do not have permission to perform this action');
  }
}

/// Asserts that [currentUser] is authenticated (non-null).
///
/// Throws [UnauthenticatedException] if [currentUser] is null.
void requireAuthenticated(User? currentUser) {
  if (currentUser == null) {
    throw const UnauthenticatedException();
  }
}
