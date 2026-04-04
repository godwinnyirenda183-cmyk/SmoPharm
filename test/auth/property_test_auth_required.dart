// Feature: pharmacy-pos, Property 22: Authentication Required
//
// Validates: Requirements 9.1
//
// Property 22: For any feature access attempt by an unauthenticated session,
// the system SHALL reject the request and redirect to the login screen.
//
// This test verifies the requireAuthenticated() guard function which is the
// enforcement point for the authentication requirement.

import 'package:glados/glados.dart';
import 'package:test/test.dart';
import 'package:pharmacy_pos/domain/entities/user.dart';
import 'package:pharmacy_pos/domain/services/role_guard.dart';

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

/// Generates a random non-empty alphanumeric string (1–20 chars).
final _genString = any.nonEmptyLetterOrDigits.map((s) =>
    s.length > 20 ? s.substring(0, 20) : s);

/// Generates a random [User] with admin role. Represents any authenticated
/// admin session.
final _genAdminUser = _genString.map(
  (id) => User(
    id: id,
    username: 'admin_$id',
    passwordHash: 'hash',
    role: UserRole.admin,
    locked: false,
    failedAttempts: 0,
    createdAt: DateTime(2024, 1, 1),
  ),
);

/// Generates a random [User] with cashier role. Represents any authenticated
/// cashier session.
final _genCashierUser = _genString.map(
  (id) => User(
    id: id,
    username: 'cashier_$id',
    passwordHash: 'hash',
    role: UserRole.cashier,
    locked: false,
    failedAttempts: 0,
    createdAt: DateTime(2024, 1, 1),
  ),
);

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

/// Minimum 100 iterations as required by the testing strategy.
final _exploreConfig = ExploreConfig(numRuns: 100);

// ---------------------------------------------------------------------------
// Property tests
// ---------------------------------------------------------------------------

void main() {
  group('Property 22: Authentication Required', () {
    // -------------------------------------------------------------------------
    // Sub-property A: Any admin-role User is accepted
    // -------------------------------------------------------------------------
    Glados(_genAdminUser, _exploreConfig).test(
      'requireAuthenticated() does NOT throw for any admin-role User',
      (user) {
        // For any admin user, requireAuthenticated() must not throw.
        expect(
          () => requireAuthenticated(user),
          returnsNormally,
          reason: 'Admin users are authenticated and must not be rejected',
        );
      },
    );

    // -------------------------------------------------------------------------
    // Sub-property B: Any cashier-role User is accepted
    // -------------------------------------------------------------------------
    Glados(_genCashierUser, _exploreConfig).test(
      'requireAuthenticated() does NOT throw for any cashier-role User',
      (user) {
        // For any cashier user, requireAuthenticated() must not throw.
        expect(
          () => requireAuthenticated(user),
          returnsNormally,
          reason: 'Cashier users are authenticated and must not be rejected',
        );
      },
    );

    // -------------------------------------------------------------------------
    // Sub-property C: Null user (unauthenticated session) is always rejected
    // -------------------------------------------------------------------------
    test(
      'requireAuthenticated() throws UnauthenticatedException for null (unauthenticated) user',
      () {
        // A null user represents an unauthenticated session.
        // The system must reject the request (throw UnauthenticatedException),
        // which signals the caller to redirect to the login screen.
        expect(
          () => requireAuthenticated(null),
          throwsA(isA<UnauthenticatedException>()),
          reason:
              'Unauthenticated (null) sessions must be rejected with UnauthenticatedException',
        );
      },
    );
  });
}
