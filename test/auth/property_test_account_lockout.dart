// Feature: pharmacy-pos, Property 23: Account Lockout After Three Failures
//
// Validates: Requirements 9.6
//
// Property 23: For any user account, after exactly three consecutive failed
// login attempts with incorrect passwords, the account SHALL be locked and
// subsequent login attempts SHALL be rejected until an admin unlocks it.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glados/glados.dart';
import 'package:pharmacy_pos/data/services/auth_service_impl.dart';
import 'package:pharmacy_pos/database/database.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

AppDatabase _openTestDb() => AppDatabase.forTesting(NativeDatabase.memory());

/// Seeds a regular (cashier) user with the given credentials.
Future<void> _seedUser(
  AppDatabase db, {
  required String username,
  required String plainPassword,
}) async {
  final hash = AuthServiceImpl.hashPassword(plainPassword);
  await db.into(db.users).insert(
        UsersCompanion.insert(
          id: 'user-$username',
          username: username,
          passwordHash: hash,
          role: 'cashier',
        ),
      );
}

/// Seeds an admin user used to unlock accounts.
Future<void> _seedAdmin(AppDatabase db) async {
  final hash = AuthServiceImpl.hashPassword('adminpass');
  await db.into(db.users).insert(
        UsersCompanion.insert(
          id: 'admin-id',
          username: 'admin',
          passwordHash: hash,
          role: 'admin',
        ),
      );
}

/// A wrong password that is guaranteed to differ from [correct].
String _wrongPassword(String correct) => '${correct}_wrong';

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

/// Generates non-empty alphanumeric usernames (1–20 chars).
final _genUsername = any.string.map(
  (s) {
    // Keep only alphanumeric chars, ensure non-empty.
    final cleaned = s.replaceAll(RegExp(r'[^a-zA-Z0-9]'), 'x');
    return cleaned.isEmpty ? 'user' : cleaned.substring(0, cleaned.length.clamp(1, 20));
  },
);

/// Generates non-empty passwords (1–20 chars).
final _genPassword = any.string.map(
  (s) {
    final cleaned = s.replaceAll(RegExp(r'[^a-zA-Z0-9!@#\$]'), 'p');
    return cleaned.isEmpty ? 'pass' : cleaned.substring(0, cleaned.length.clamp(1, 20));
  },
);

// ---------------------------------------------------------------------------
// Property tests
// ---------------------------------------------------------------------------

/// Minimum 100 iterations as required by the testing strategy.
const _exploreConfig = ExploreConfig(numRuns: 100);

void main() {
  group('Property 23: Account Lockout After Three Failures', () {
    // -------------------------------------------------------------------------
    // Sub-property A: Exactly 3 failures lock the account
    // -------------------------------------------------------------------------
    Glados2(_genUsername, _genPassword, _exploreConfig).test(
      'after exactly 3 wrong-password attempts the account is locked',
      (username, password) async {
        final db = _openTestDb();
        try {
          await _seedUser(db, username: username, plainPassword: password);
          final auth = AuthServiceImpl(db);
          final wrong = _wrongPassword(password);

          // 3 consecutive wrong-password attempts
          for (var i = 0; i < 3; i++) {
            try {
              await auth.login(username, wrong);
            } on ArgumentError {
              // expected for first two failures
            } on StateError {
              // expected on the 3rd failure (account just locked)
            }
          }

          // Verify the row is locked in the database
          final row = await (db.select(db.users)
                ..where((u) => u.username.equals(username)))
              .getSingle();
          expect(row.locked, isTrue,
              reason: 'Account must be locked after 3 failed attempts');
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Sub-property B: After locking, even the correct password is rejected
    // -------------------------------------------------------------------------
    Glados2(_genUsername, _genPassword, _exploreConfig).test(
      'after 3 failures, correct password is rejected with StateError',
      (username, password) async {
        final db = _openTestDb();
        try {
          await _seedUser(db, username: username, plainPassword: password);
          final auth = AuthServiceImpl(db);
          final wrong = _wrongPassword(password);

          // Lock the account
          for (var i = 0; i < 3; i++) {
            try {
              await auth.login(username, wrong);
            } catch (_) {}
          }

          // Correct password must now throw StateError
          expect(
            () => auth.login(username, password),
            throwsA(isA<StateError>().having(
              (e) => e.message,
              'message',
              'Account locked. Contact your administrator.',
            )),
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Sub-property C: After admin unlock, login succeeds again
    // -------------------------------------------------------------------------
    Glados2(_genUsername, _genPassword, _exploreConfig).test(
      'after admin unlock, the account can be logged into again',
      (username, password) async {
        final db = _openTestDb();
        try {
          await _seedAdmin(db);
          await _seedUser(db, username: username, plainPassword: password);
          final auth = AuthServiceImpl(db);
          final wrong = _wrongPassword(password);

          // Lock the account
          for (var i = 0; i < 3; i++) {
            try {
              await auth.login(username, wrong);
            } catch (_) {}
          }

          // Admin logs in and unlocks the account
          await auth.login('admin', 'adminpass');
          await auth.unlockAccount(username);
          await auth.logout();

          // The user should now be able to log in with the correct password
          final user = await auth.login(username, password);
          expect(user.username, equals(username),
              reason: 'Login must succeed after admin unlock');
          expect(user.locked, isFalse,
              reason: 'User must not be locked after unlock');
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Sub-property D: Fewer than 3 failures do NOT lock the account
    // -------------------------------------------------------------------------
    Glados2(_genUsername, _genPassword, _exploreConfig).test(
      'fewer than 3 consecutive failures do NOT lock the account',
      (username, password) async {
        final db = _openTestDb();
        try {
          await _seedUser(db, username: username, plainPassword: password);
          final auth = AuthServiceImpl(db);
          final wrong = _wrongPassword(password);

          // 0 or 1 or 2 failures — use 2 (the maximum that must NOT lock)
          for (var i = 0; i < 2; i++) {
            try {
              await auth.login(username, wrong);
            } catch (_) {}
          }

          final row = await (db.select(db.users)
                ..where((u) => u.username.equals(username)))
              .getSingle();
          expect(row.locked, isFalse,
              reason: 'Account must NOT be locked after fewer than 3 failures');
        } finally {
          await db.close();
        }
      },
    );
  });
}
