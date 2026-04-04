// Feature: pharmacy-pos, Property 21: Role-Based Access Enforcement
//
// Validates: Requirements 1.1, 1.2, 4.1, 5.8, 9.3, 9.4
//
// Property 21: For any operation restricted to admin role (product management,
// stock adjustments, report generation, void sale, settings), any attempt by a
// cashier-role user SHALL be rejected. For any such operation attempted by an
// admin-role user, it SHALL be permitted.

import 'package:flutter_test/flutter_test.dart';
import 'package:glados/glados.dart';
import 'package:pharmacy_pos/data/services/auth_service_impl.dart';
import 'package:pharmacy_pos/domain/entities/user.dart';
import 'package:pharmacy_pos/domain/services/role_guard.dart';

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

/// Generates a random non-empty string suitable for user fields (1–20 chars).
final _genString = any.string.map((s) {
  final cleaned = s.replaceAll(RegExp(r'[^a-zA-Z0-9]'), 'x');
  return cleaned.isEmpty ? 'val' : cleaned.substring(0, cleaned.length.clamp(1, 20));
});

/// Generates a random [User] with [UserRole.admin].
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

/// Generates a random [User] with [UserRole.cashier].
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
const _exploreConfig = ExploreConfig(numRuns: 100);

// ---------------------------------------------------------------------------
// Property tests
// ---------------------------------------------------------------------------

void main() {
  group('Property 21: Role-Based Access Enforcement', () {
    // -------------------------------------------------------------------------
    // Sub-property A: Admin users are always permitted
    // -------------------------------------------------------------------------
    Glados(_genAdminUser, _exploreConfig).test(
      'requireAdmin() does NOT throw for any admin-role user',
      (user) {
        // For any admin user, requireAdmin must not throw.
        expect(
          () => requireAdmin(user),
          returnsNormally,
          reason: 'Admin users must be permitted to perform restricted operations',
        );
      },
    );

    // -------------------------------------------------------------------------
    // Sub-property B: Cashier users are always rejected
    // -------------------------------------------------------------------------
    Glados(_genCashierUser, _exploreConfig).test(
      'requireAdmin() throws UnauthorizedException for any cashier-role user',
      (user) {
        // For any cashier user, requireAdmin must throw UnauthorizedException
        // with the standard permission-denied message.
        expect(
          () => requireAdmin(user),
          throwsA(
            isA<UnauthorizedException>().having(
              (e) => e.message,
              'message',
              'You do not have permission to perform this action',
            ),
          ),
          reason: 'Cashier users must be rejected from restricted operations',
        );
      },
    );

    // -------------------------------------------------------------------------
    // Sub-property C: Null user (unauthenticated) is always rejected
    // -------------------------------------------------------------------------
    test(
      'requireAdmin() throws UnauthorizedException for null (unauthenticated) user',
      () {
        expect(
          () => requireAdmin(null),
          throwsA(
            isA<UnauthorizedException>().having(
              (e) => e.message,
              'message',
              'You do not have permission to perform this action',
            ),
          ),
          reason: 'Unauthenticated (null) users must be rejected from restricted operations',
        );
      },
    );
  });
}
