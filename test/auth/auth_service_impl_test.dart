// ignore_for_file: avoid_print

import 'package:bcrypt/bcrypt.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_pos/data/services/auth_service_impl.dart';
import 'package:pharmacy_pos/database/database.dart';
import 'package:pharmacy_pos/domain/entities/user.dart';
import 'package:pharmacy_pos/domain/services/auth_service.dart';

AppDatabase _openTestDb() => AppDatabase.forTesting(NativeDatabase.memory());

/// Inserts a user row directly into the database for test setup.
Future<void> _seedUser(
  AppDatabase db, {
  required String id,
  required String username,
  required String plainPassword,
  String role = 'cashier',
  bool locked = false,
  int failedAttempts = 0,
}) async {
  final hash = AuthServiceImpl.hashPassword(plainPassword);
  await db.into(db.users).insert(
        UsersCompanion.insert(
          id: id,
          username: username,
          passwordHash: hash,
          role: role,
          locked: Value(locked),
          failedAttempts: Value(failedAttempts),
        ),
      );
}

void main() {
  group('AuthServiceImpl', () {
    late AppDatabase db;
    late AuthServiceImpl auth;

    setUp(() {
      db = _openTestDb();
      auth = AuthServiceImpl(db);
    });

    tearDown(() async {
      await db.close();
    });

    // -------------------------------------------------------------------------
    // login — success
    // -------------------------------------------------------------------------

    test('login returns User on correct credentials', () async {
      await _seedUser(db,
          id: 'u1', username: 'alice', plainPassword: 'secret', role: 'admin');

      final user = await auth.login('alice', 'secret');

      expect(user.username, equals('alice'));
      expect(user.role, equals(UserRole.admin));
      expect(user.locked, isFalse);
      expect(user.failedAttempts, equals(0));
    });

    test('login sets currentUser on success', () async {
      await _seedUser(db,
          id: 'u1', username: 'alice', plainPassword: 'secret');

      expect(auth.currentUser, isNull);
      await auth.login('alice', 'secret');
      expect(auth.currentUser, isNotNull);
      expect(auth.currentUser!.username, equals('alice'));
    });

    test('login emits authenticated session state on success', () async {
      await _seedUser(db,
          id: 'u1', username: 'alice', plainPassword: 'secret');

      final states = <SessionState>[];
      auth.sessionStream.listen(states.add);

      await auth.login('alice', 'secret');
      await Future<void>.delayed(Duration.zero);

      expect(states, contains(SessionState.authenticated));
    });

    test('login resets failed_attempts to 0 on success', () async {
      await _seedUser(db,
          id: 'u1',
          username: 'alice',
          plainPassword: 'secret',
          failedAttempts: 2);

      await auth.login('alice', 'secret');

      final row = await (db.select(db.users)
            ..where((u) => u.username.equals('alice')))
          .getSingle();
      expect(row.failedAttempts, equals(0));
    });

    // -------------------------------------------------------------------------
    // login — wrong password
    // -------------------------------------------------------------------------

    test('login throws ArgumentError on wrong password', () async {
      await _seedUser(db,
          id: 'u1', username: 'alice', plainPassword: 'secret');

      expect(
        () => auth.login('alice', 'wrong'),
        throwsA(isA<ArgumentError>().having(
            (e) => e.message, 'message', 'Invalid username or password')),
      );
    });

    test('login throws ArgumentError on unknown username', () async {
      expect(
        () => auth.login('nobody', 'secret'),
        throwsA(isA<ArgumentError>().having(
            (e) => e.message, 'message', 'Invalid username or password')),
      );
    });

    test('login increments failed_attempts on wrong password', () async {
      await _seedUser(db,
          id: 'u1', username: 'alice', plainPassword: 'secret');

      try {
        await auth.login('alice', 'wrong');
      } catch (_) {}

      final row = await (db.select(db.users)
            ..where((u) => u.username.equals('alice')))
          .getSingle();
      expect(row.failedAttempts, equals(1));
    });

    test('failed_attempts increments on each wrong password', () async {
      await _seedUser(db,
          id: 'u1', username: 'alice', plainPassword: 'secret');

      for (var i = 1; i <= 2; i++) {
        try {
          await auth.login('alice', 'wrong');
        } catch (_) {}
      }

      final row = await (db.select(db.users)
            ..where((u) => u.username.equals('alice')))
          .getSingle();
      expect(row.failedAttempts, equals(2));
    });

    // -------------------------------------------------------------------------
    // login — lockout after 3 failures
    // -------------------------------------------------------------------------

    test('account is locked after 3 consecutive wrong passwords', () async {
      await _seedUser(db,
          id: 'u1', username: 'alice', plainPassword: 'secret');

      for (var i = 0; i < 3; i++) {
        try {
          await auth.login('alice', 'wrong');
        } catch (_) {}
      }

      final row = await (db.select(db.users)
            ..where((u) => u.username.equals('alice')))
          .getSingle();
      expect(row.locked, isTrue);
    });

    test('3rd wrong password throws StateError with lockout message', () async {
      await _seedUser(db,
          id: 'u1',
          username: 'alice',
          plainPassword: 'secret',
          failedAttempts: 2);

      expect(
        () => auth.login('alice', 'wrong'),
        throwsA(isA<StateError>().having((e) => e.message, 'message',
            'Account locked. Contact your administrator.')),
      );
    });

    test('login on locked account throws StateError', () async {
      await _seedUser(db,
          id: 'u1',
          username: 'alice',
          plainPassword: 'secret',
          locked: true);

      expect(
        () => auth.login('alice', 'secret'),
        throwsA(isA<StateError>().having((e) => e.message, 'message',
            'Account locked. Contact your administrator.')),
      );
    });

    // -------------------------------------------------------------------------
    // logout
    // -------------------------------------------------------------------------

    test('logout clears currentUser', () async {
      await _seedUser(db,
          id: 'u1', username: 'alice', plainPassword: 'secret');
      await auth.login('alice', 'secret');

      await auth.logout();

      expect(auth.currentUser, isNull);
    });

    test('logout emits unauthenticated session state', () async {
      await _seedUser(db,
          id: 'u1', username: 'alice', plainPassword: 'secret');
      await auth.login('alice', 'secret');

      final states = <SessionState>[];
      auth.sessionStream.listen(states.add);

      await auth.logout();

      expect(states, contains(SessionState.unauthenticated));
    });

    // -------------------------------------------------------------------------
    // unlockAccount
    // -------------------------------------------------------------------------

    test('admin can unlock a locked account', () async {
      await _seedUser(db,
          id: 'admin1', username: 'admin', plainPassword: 'adminpass',
          role: 'admin');
      await _seedUser(db,
          id: 'u1',
          username: 'alice',
          plainPassword: 'secret',
          locked: true,
          failedAttempts: 3);

      await auth.login('admin', 'adminpass');
      await auth.unlockAccount('alice');

      final row = await (db.select(db.users)
            ..where((u) => u.username.equals('alice')))
          .getSingle();
      expect(row.locked, isFalse);
      expect(row.failedAttempts, equals(0));
    });

    test('unlockAccount resets failed_attempts to 0', () async {
      await _seedUser(db,
          id: 'admin1', username: 'admin', plainPassword: 'adminpass',
          role: 'admin');
      await _seedUser(db,
          id: 'u1',
          username: 'alice',
          plainPassword: 'secret',
          locked: true,
          failedAttempts: 3);

      await auth.login('admin', 'adminpass');
      await auth.unlockAccount('alice');

      final row = await (db.select(db.users)
            ..where((u) => u.username.equals('alice')))
          .getSingle();
      expect(row.failedAttempts, equals(0));
    });

    test('cashier cannot unlock an account — throws UnauthorizedException',
        () async {
      await _seedUser(db,
          id: 'c1', username: 'cashier', plainPassword: 'pass',
          role: 'cashier');
      await _seedUser(db,
          id: 'u1',
          username: 'alice',
          plainPassword: 'secret',
          locked: true);

      await auth.login('cashier', 'pass');

      expect(
        () => auth.unlockAccount('alice'),
        throwsA(isA<UnauthorizedException>()),
      );
    });

    test('unauthenticated caller cannot unlock — throws UnauthorizedException',
        () async {
      await _seedUser(db,
          id: 'u1',
          username: 'alice',
          plainPassword: 'secret',
          locked: true);

      expect(
        () => auth.unlockAccount('alice'),
        throwsA(isA<UnauthorizedException>()),
      );
    });

    test('unlocked account can be logged into again', () async {
      await _seedUser(db,
          id: 'admin1', username: 'admin', plainPassword: 'adminpass',
          role: 'admin');
      await _seedUser(db,
          id: 'u1',
          username: 'alice',
          plainPassword: 'secret',
          locked: true,
          failedAttempts: 3);

      await auth.login('admin', 'adminpass');
      await auth.unlockAccount('alice');
      await auth.logout();

      // Alice should now be able to log in.
      final user = await auth.login('alice', 'secret');
      expect(user.username, equals('alice'));
    });

    // -------------------------------------------------------------------------
    // hashPassword utility
    // -------------------------------------------------------------------------

    test('hashPassword produces a valid bcrypt hash', () async {
      final hash = AuthServiceImpl.hashPassword('mypassword');
      expect(BCrypt.checkpw('mypassword', hash), isTrue);
      expect(BCrypt.checkpw('wrongpassword', hash), isFalse);
    });

    test('hashPassword uses cost factor 12', () async {
      final hash = AuthServiceImpl.hashPassword('mypassword');
      // bcrypt hash format: $2b$<cost>$...
      expect(hash, startsWith(r'$2a$12$'));
    });
  });
}
