// Feature: pharmacy-pos, Integration: Session Timeout
//
// Integration tests for the 15-minute inactivity session timeout.
//
// These tests use [FakeClock] and [FakeAuthService] injected via Riverpod
// provider overrides so no real timers or databases are needed.
// [SessionTimeoutNotifier.checkTimeoutForTest] is used to trigger the
// timeout check synchronously instead of waiting for the real 30-second
// periodic timer.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_pos/domain/entities/user.dart';
import 'package:pharmacy_pos/domain/services/auth_service.dart';
import 'package:pharmacy_pos/providers/session_timeout_provider.dart';

// ---------------------------------------------------------------------------
// Fake clock
// ---------------------------------------------------------------------------

class FakeClock implements Clock {
  DateTime _now;

  FakeClock([DateTime? initial])
      : _now = initial ?? DateTime(2024, 6, 1, 9, 0, 0);

  @override
  DateTime now() => _now;

  void advance(Duration d) => _now = _now.add(d);
}

// ---------------------------------------------------------------------------
// Fake AuthService
// ---------------------------------------------------------------------------

class FakeAuthService implements AuthService {
  User? _currentUser;
  final StreamController<SessionState> _ctrl =
      StreamController<SessionState>.broadcast();

  bool logoutCalled = false;

  @override
  User? get currentUser => _currentUser;

  @override
  Stream<SessionState> get sessionStream => _ctrl.stream;

  void emit(SessionState s) => _ctrl.add(s);
  void setUser(User? u) => _currentUser = u;

  @override
  Future<User> login(String username, String password) =>
      throw UnimplementedError();

  @override
  Future<void> logout() async {
    logoutCalled = true;
    _currentUser = null;
    _ctrl.add(SessionState.unauthenticated);
  }

  @override
  Future<void> unlockAccount(String username) => throw UnimplementedError();

  void dispose() => _ctrl.close();
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

User _user() => User(
      id: 'u1',
      username: 'bob',
      passwordHash: 'hash',
      role: UserRole.admin,
      locked: false,
      failedAttempts: 0,
      createdAt: DateTime(2024),
    );

ProviderContainer _container({
  required FakeClock clock,
  required FakeAuthService auth,
}) =>
    ProviderContainer(overrides: [
      clockProvider.overrideWithValue(clock),
      authServiceProvider.overrideWithValue(auth),
    ]);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('Session timeout integration', () {
    late FakeClock clock;
    late FakeAuthService auth;
    late ProviderContainer container;

    setUp(() {
      clock = FakeClock();
      auth = FakeAuthService();
    });

    tearDown(() {
      container.dispose();
      auth.dispose();
    });

    // -----------------------------------------------------------------------
    // 1. Session locks after exactly 15 minutes of inactivity
    // -----------------------------------------------------------------------

    test('session locks after 15 minutes of inactivity', () async {
      auth.setUser(_user());
      container = _container(clock: clock, auth: auth);
      container.read(sessionTimeoutProvider); // initialise

      clock.advance(const Duration(minutes: 15));
      container.read(sessionTimeoutProvider.notifier).checkTimeoutForTest();
      await Future<void>.delayed(Duration.zero);

      expect(container.read(sessionTimeoutProvider), SessionState.locked);
    });

    // -----------------------------------------------------------------------
    // 2. Session does NOT lock before 15 minutes
    // -----------------------------------------------------------------------

    test('session stays authenticated before 15 minutes', () async {
      auth.setUser(_user());
      container = _container(clock: clock, auth: auth);
      container.read(sessionTimeoutProvider);

      clock.advance(const Duration(minutes: 14, seconds: 59));
      container.read(sessionTimeoutProvider.notifier).checkTimeoutForTest();
      await Future<void>.delayed(Duration.zero);

      expect(
          container.read(sessionTimeoutProvider), SessionState.authenticated);
    });

    // -----------------------------------------------------------------------
    // 3. logout() is called on the AuthService when session times out
    // -----------------------------------------------------------------------

    test('AuthService.logout is called when session times out', () async {
      auth.setUser(_user());
      container = _container(clock: clock, auth: auth);
      container.read(sessionTimeoutProvider);

      clock.advance(const Duration(minutes: 15));
      container.read(sessionTimeoutProvider.notifier).checkTimeoutForTest();
      await Future<void>.delayed(Duration.zero);

      expect(auth.logoutCalled, isTrue);
    });

    // -----------------------------------------------------------------------
    // 4. resetTimer postpones the lock
    // -----------------------------------------------------------------------

    test('resetTimer postpones the lock past 15 minutes', () async {
      auth.setUser(_user());
      container = _container(clock: clock, auth: auth);
      container.read(sessionTimeoutProvider);

      final notifier = container.read(sessionTimeoutProvider.notifier);

      // Advance to 14:59 — just before timeout.
      clock.advance(const Duration(minutes: 14, seconds: 59));
      notifier.resetTimer(); // user activity resets the clock reference

      // Advance another 14 minutes (only 14 min since last reset).
      clock.advance(const Duration(minutes: 14));
      notifier.checkTimeoutForTest();
      await Future<void>.delayed(Duration.zero);

      // Should still be authenticated — only 14 min since last activity.
      expect(
          container.read(sessionTimeoutProvider), SessionState.authenticated);
    });

    // -----------------------------------------------------------------------
    // 5. Session locks after 15 minutes following a reset
    // -----------------------------------------------------------------------

    test('session locks 15 minutes after the last resetTimer call', () async {
      auth.setUser(_user());
      container = _container(clock: clock, auth: auth);
      container.read(sessionTimeoutProvider);

      final notifier = container.read(sessionTimeoutProvider.notifier);

      // Activity at t=10 min.
      clock.advance(const Duration(minutes: 10));
      notifier.resetTimer();

      // Advance 15 more minutes from the reset point.
      clock.advance(const Duration(minutes: 15));
      notifier.checkTimeoutForTest();
      await Future<void>.delayed(Duration.zero);

      expect(container.read(sessionTimeoutProvider), SessionState.locked);
    });

    // -----------------------------------------------------------------------
    // 6. Continuous activity keeps session alive well past 15 minutes
    // -----------------------------------------------------------------------

    test('continuous activity keeps session alive past 30 minutes', () async {
      auth.setUser(_user());
      container = _container(clock: clock, auth: auth);
      container.read(sessionTimeoutProvider);

      final notifier = container.read(sessionTimeoutProvider.notifier);

      // Simulate user activity every 5 minutes for 30 minutes.
      for (var i = 0; i < 6; i++) {
        clock.advance(const Duration(minutes: 5));
        notifier.resetTimer();
        notifier.checkTimeoutForTest();
        await Future<void>.delayed(Duration.zero);

        expect(
          container.read(sessionTimeoutProvider),
          SessionState.authenticated,
          reason: 'Should be authenticated at ${(i + 1) * 5} minutes with '
              'activity every 5 minutes',
        );
      }
    });

    // -----------------------------------------------------------------------
    // 7. Unauthenticated session is never locked by the timeout
    // -----------------------------------------------------------------------

    test('unauthenticated session is not affected by timeout check', () async {
      // No user set — starts unauthenticated.
      container = _container(clock: clock, auth: auth);
      container.read(sessionTimeoutProvider);

      clock.advance(const Duration(hours: 1));
      container.read(sessionTimeoutProvider.notifier).checkTimeoutForTest();
      await Future<void>.delayed(Duration.zero);

      // Should remain unauthenticated, not locked.
      expect(
          container.read(sessionTimeoutProvider), SessionState.unauthenticated);
    });

    // -----------------------------------------------------------------------
    // 8. Login followed by 15 minutes inactivity locks the session
    // -----------------------------------------------------------------------

    test('login then 15 minutes inactivity locks the session', () async {
      container = _container(clock: clock, auth: auth);
      container.read(sessionTimeoutProvider);

      // Simulate login event from the auth service stream.
      auth.setUser(_user());
      auth.emit(SessionState.authenticated);
      await Future<void>.delayed(Duration.zero);

      expect(
          container.read(sessionTimeoutProvider), SessionState.authenticated);

      // Advance 15 minutes without any activity.
      clock.advance(const Duration(minutes: 15));
      container.read(sessionTimeoutProvider.notifier).checkTimeoutForTest();
      await Future<void>.delayed(Duration.zero);

      expect(container.read(sessionTimeoutProvider), SessionState.locked);
    });

    // -----------------------------------------------------------------------
    // 9. Locked state persists even after auth service emits unauthenticated
    // -----------------------------------------------------------------------

    test('locked state is not overwritten by unauthenticated event', () async {
      auth.setUser(_user());
      container = _container(clock: clock, auth: auth);
      container.read(sessionTimeoutProvider);

      clock.advance(const Duration(minutes: 15));
      container.read(sessionTimeoutProvider.notifier).checkTimeoutForTest();
      await Future<void>.delayed(Duration.zero);

      // Timeout triggers logout which emits unauthenticated — state should
      // remain locked so the lock screen stays visible.
      expect(container.read(sessionTimeoutProvider), SessionState.locked);
    });
  });
}
