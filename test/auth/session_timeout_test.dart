// ignore_for_file: avoid_print

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_pos/domain/entities/user.dart';
import 'package:pharmacy_pos/domain/services/auth_service.dart';
import 'package:pharmacy_pos/providers/session_timeout_provider.dart';

// ---------------------------------------------------------------------------
// Fake clock
// ---------------------------------------------------------------------------

/// A controllable fake clock for tests.
class FakeClock implements Clock {
  DateTime _now;

  FakeClock([DateTime? initial])
      : _now = initial ?? DateTime(2024, 1, 1, 12, 0, 0);

  @override
  DateTime now() => _now;

  /// Advance the clock by [duration].
  void advance(Duration duration) {
    _now = _now.add(duration);
  }
}

// ---------------------------------------------------------------------------
// Fake AuthService
// ---------------------------------------------------------------------------

class FakeAuthService implements AuthService {
  User? _currentUser;
  final StreamController<SessionState> _controller =
      StreamController<SessionState>.broadcast();

  bool logoutCalled = false;

  @override
  User? get currentUser => _currentUser;

  @override
  Stream<SessionState> get sessionStream => _controller.stream;

  void emitState(SessionState s) => _controller.add(s);

  void setCurrentUser(User? user) => _currentUser = user;

  @override
  Future<User> login(String username, String password) async {
    throw UnimplementedError();
  }

  @override
  Future<void> logout() async {
    logoutCalled = true;
    _currentUser = null;
    _controller.add(SessionState.unauthenticated);
  }

  @override
  Future<void> unlockAccount(String username) async {
    throw UnimplementedError();
  }

  void dispose() => _controller.close();
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

User _fakeUser() => User(
      id: 'u1',
      username: 'alice',
      passwordHash: 'hash',
      role: UserRole.cashier,
      locked: false,
      failedAttempts: 0,
      createdAt: DateTime(2024),
    );

/// Builds a [ProviderContainer] wired with [FakeClock] and [FakeAuthService].
ProviderContainer _buildContainer({
  required FakeClock clock,
  required FakeAuthService authService,
}) {
  return ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(clock),
      authServiceProvider.overrideWithValue(authService),
    ],
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('SessionTimeoutNotifier', () {
    late FakeClock clock;
    late FakeAuthService authService;
    late ProviderContainer container;

    setUp(() {
      clock = FakeClock();
      authService = FakeAuthService();
    });

    tearDown(() {
      container.dispose();
      authService.dispose();
    });

    // -----------------------------------------------------------------------
    // Initial state
    // -----------------------------------------------------------------------

    test('initial state is unauthenticated when no user is logged in', () {
      container = _buildContainer(clock: clock, authService: authService);
      expect(
        container.read(sessionTimeoutProvider),
        equals(SessionState.unauthenticated),
      );
    });

    test('initial state is authenticated when a user is already logged in', () {
      authService.setCurrentUser(_fakeUser());
      container = _buildContainer(clock: clock, authService: authService);
      expect(
        container.read(sessionTimeoutProvider),
        equals(SessionState.authenticated),
      );
    });

    // -----------------------------------------------------------------------
    // Session state mirrors auth service stream
    // -----------------------------------------------------------------------

    test('state becomes authenticated when auth service emits authenticated',
        () async {
      container = _buildContainer(clock: clock, authService: authService);
      container.read(sessionTimeoutProvider); // initialise

      authService.emitState(SessionState.authenticated);
      await Future<void>.delayed(Duration.zero);

      expect(
        container.read(sessionTimeoutProvider),
        equals(SessionState.authenticated),
      );
    });

    test('state becomes unauthenticated when auth service emits unauthenticated',
        () async {
      authService.setCurrentUser(_fakeUser());
      container = _buildContainer(clock: clock, authService: authService);
      container.read(sessionTimeoutProvider);

      authService.emitState(SessionState.unauthenticated);
      await Future<void>.delayed(Duration.zero);

      expect(
        container.read(sessionTimeoutProvider),
        equals(SessionState.unauthenticated),
      );
    });

    // -----------------------------------------------------------------------
    // resetTimer
    // -----------------------------------------------------------------------

    test('resetTimer does nothing when session is not authenticated', () {
      container = _buildContainer(clock: clock, authService: authService);
      container.read(sessionTimeoutProvider);

      // Should not throw; state stays unauthenticated.
      container.read(sessionTimeoutProvider.notifier).resetTimer();
      expect(
        container.read(sessionTimeoutProvider),
        equals(SessionState.unauthenticated),
      );
    });

    test('resetTimer postpones timeout when session is authenticated', () async {
      authService.setCurrentUser(_fakeUser());
      container = _buildContainer(clock: clock, authService: authService);
      container.read(sessionTimeoutProvider);

      // Advance clock to just before timeout.
      clock.advance(const Duration(minutes: 14, seconds: 59));

      // Reset the timer — this should push the deadline forward.
      container.read(sessionTimeoutProvider.notifier).resetTimer();

      // Advance another 14 minutes (total 29 min from start, but only 14 from reset).
      clock.advance(const Duration(minutes: 14));

      // Manually trigger the check (simulating the periodic timer firing).
      final notifier = container.read(sessionTimeoutProvider.notifier);
      notifier.checkTimeoutForTest();
      await Future<void>.delayed(Duration.zero);

      // Should still be authenticated because only 14 min elapsed since reset.
      expect(
        container.read(sessionTimeoutProvider),
        equals(SessionState.authenticated),
      );
    });

    // -----------------------------------------------------------------------
    // Timeout — session locks after 15 minutes of inactivity
    // -----------------------------------------------------------------------

    test('session locks after 15 minutes of inactivity', () async {
      authService.setCurrentUser(_fakeUser());
      container = _buildContainer(clock: clock, authService: authService);
      container.read(sessionTimeoutProvider);

      // Advance clock past the 15-minute threshold.
      clock.advance(const Duration(minutes: 15));

      // Trigger the timeout check.
      final notifier = container.read(sessionTimeoutProvider.notifier);
      notifier.checkTimeoutForTest();
      await Future<void>.delayed(Duration.zero);

      expect(
        container.read(sessionTimeoutProvider),
        equals(SessionState.locked),
      );
    });

    test('session does NOT lock before 15 minutes have elapsed', () async {
      authService.setCurrentUser(_fakeUser());
      container = _buildContainer(clock: clock, authService: authService);
      container.read(sessionTimeoutProvider);

      // Advance to just under the threshold.
      clock.advance(const Duration(minutes: 14, seconds: 59));

      final notifier = container.read(sessionTimeoutProvider.notifier);
      notifier.checkTimeoutForTest();
      await Future<void>.delayed(Duration.zero);

      expect(
        container.read(sessionTimeoutProvider),
        equals(SessionState.authenticated),
      );
    });

    test('logout is called on the auth service when session times out',
        () async {
      authService.setCurrentUser(_fakeUser());
      container = _buildContainer(clock: clock, authService: authService);
      container.read(sessionTimeoutProvider);

      clock.advance(const Duration(minutes: 15));

      final notifier = container.read(sessionTimeoutProvider.notifier);
      notifier.checkTimeoutForTest();
      await Future<void>.delayed(Duration.zero);

      expect(authService.logoutCalled, isTrue);
    });

    test('session locks at exactly 15 minutes (boundary)', () async {
      authService.setCurrentUser(_fakeUser());
      container = _buildContainer(clock: clock, authService: authService);
      container.read(sessionTimeoutProvider);

      clock.advance(const Duration(minutes: 15));

      final notifier = container.read(sessionTimeoutProvider.notifier);
      notifier.checkTimeoutForTest();
      await Future<void>.delayed(Duration.zero);

      expect(
        container.read(sessionTimeoutProvider),
        equals(SessionState.locked),
      );
    });

    // -----------------------------------------------------------------------
    // Timer reset keeps session alive
    // -----------------------------------------------------------------------

    test('repeated resetTimer calls keep session alive past 15 minutes',
        () async {
      authService.setCurrentUser(_fakeUser());
      container = _buildContainer(clock: clock, authService: authService);
      container.read(sessionTimeoutProvider);

      final notifier = container.read(sessionTimeoutProvider.notifier);

      // Simulate user activity every 10 minutes for 30 minutes.
      for (var i = 0; i < 3; i++) {
        clock.advance(const Duration(minutes: 10));
        notifier.resetTimer();
        notifier.checkTimeoutForTest();
        await Future<void>.delayed(Duration.zero);

        expect(
          container.read(sessionTimeoutProvider),
          equals(SessionState.authenticated),
          reason: 'Should still be authenticated after ${(i + 1) * 10} minutes '
              'with activity every 10 minutes',
        );
      }
    });
  });
}
