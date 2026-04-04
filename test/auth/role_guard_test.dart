import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_pos/data/services/auth_service_impl.dart';
import 'package:pharmacy_pos/domain/entities/user.dart';
import 'package:pharmacy_pos/domain/services/role_guard.dart';

User _makeUser(UserRole role) => User(
      id: 'test-id',
      username: 'testuser',
      passwordHash: 'hash',
      role: role,
      locked: false,
      failedAttempts: 0,
      createdAt: DateTime(2024),
    );

void main() {
  group('requireAdmin', () {
    test('admin user passes without throwing', () {
      final admin = _makeUser(UserRole.admin);
      expect(() => requireAdmin(admin), returnsNormally);
    });

    test('cashier user throws UnauthorizedException', () {
      final cashier = _makeUser(UserRole.cashier);
      expect(
        () => requireAdmin(cashier),
        throwsA(isA<UnauthorizedException>().having(
          (e) => e.message,
          'message',
          'You do not have permission to perform this action',
        )),
      );
    });

    test('null user throws UnauthorizedException', () {
      expect(
        () => requireAdmin(null),
        throwsA(isA<UnauthorizedException>().having(
          (e) => e.message,
          'message',
          'You do not have permission to perform this action',
        )),
      );
    });
  });

  group('requireAuthenticated', () {
    test('authenticated user passes without throwing', () {
      final user = _makeUser(UserRole.cashier);
      expect(() => requireAuthenticated(user), returnsNormally);
    });

    test('null user throws UnauthenticatedException', () {
      expect(
        () => requireAuthenticated(null),
        throwsA(isA<UnauthenticatedException>()),
      );
    });
  });
}
