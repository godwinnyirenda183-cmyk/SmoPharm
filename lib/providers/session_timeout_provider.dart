import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pharmacy_pos/data/services/auth_service_impl.dart';
import 'package:pharmacy_pos/domain/services/auth_service.dart';
import 'package:pharmacy_pos/providers/database_provider.dart';

/// Abstraction over the current time, allowing tests to inject a fake clock
/// without waiting 15 real minutes.
abstract class Clock {
  DateTime now();
}

/// Production clock that delegates to [DateTime.now].
class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime now() => DateTime.now();
}

/// Duration of inactivity before the session is automatically locked.
const Duration kSessionTimeout = Duration(minutes: 15);

/// How often the timeout notifier checks whether the session has expired.
const Duration kTimeoutCheckInterval = Duration(seconds: 30);

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

/// Provides the [Clock] implementation.  Override in tests with a fake clock.
final clockProvider = Provider<Clock>((ref) => const SystemClock());

/// Provides the [AuthService] instance backed by the Drift [AppDatabase].
final authServiceProvider = Provider<AuthService>((ref) {
  final db = ref.watch(databaseProvider);
  return AuthServiceImpl(db);
});

// ---------------------------------------------------------------------------
// SessionTimeoutNotifier
// ---------------------------------------------------------------------------

/// Tracks inactivity and locks the session after [kSessionTimeout].
///
/// Call [resetTimer] on every user interaction to postpone the lock.
/// The notifier emits [SessionState] values that mirror [AuthService.sessionStream].
class SessionTimeoutNotifier extends Notifier<SessionState> {
  Timer? _checkTimer;
  DateTime? _lastActivity;

  /// Injected clock — defaults to [SystemClock] but can be replaced in tests.
  Clock get _clock => ref.read(clockProvider);

  @override
  SessionState build() {
    // Start listening to the auth service session stream so that external
    // login / logout events are reflected in this notifier's state.
    final authService = ref.read(authServiceProvider);
    final sub = authService.sessionStream.listen(_onSessionStateChanged);
    ref.onDispose(sub.cancel);

    // Seed the initial state from the auth service.
    final initialState = authService.currentUser != null
        ? SessionState.authenticated
        : SessionState.unauthenticated;

    if (initialState == SessionState.authenticated) {
      _startTimer();
    }

    return initialState;
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Resets the inactivity timer.  Call this on every user interaction.
  void resetTimer() {
    if (state == SessionState.authenticated) {
      _lastActivity = _clock.now();
    }
  }

  /// Exposed for testing: immediately runs the timeout check logic without
  /// waiting for the periodic [Timer] to fire.
  void checkTimeoutForTest() => _checkTimeout();

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  void _onSessionStateChanged(SessionState newState) {
    if (newState == SessionState.authenticated) {
      _lastActivity = _clock.now();
      _startTimer();
    } else {
      _stopTimer();
    }
    // Don't overwrite a locked state with unauthenticated — the lock screen
    // should remain visible until the user explicitly logs in again.
    if (state == SessionState.locked && newState == SessionState.unauthenticated) {
      return;
    }
    state = newState;
  }

  void _startTimer() {
    _stopTimer();
    _lastActivity = _clock.now();
    _checkTimer = Timer.periodic(kTimeoutCheckInterval, (_) => _checkTimeout());
  }

  void _stopTimer() {
    _checkTimer?.cancel();
    _checkTimer = null;
  }

  void _checkTimeout() {
    if (state != SessionState.authenticated) {
      _stopTimer();
      return;
    }

    final last = _lastActivity;
    if (last == null) return;

    final elapsed = _clock.now().difference(last);
    if (elapsed >= kSessionTimeout) {
      _lockSession();
    }
  }

  Future<void> _lockSession() async {
    _stopTimer();
    state = SessionState.locked;
    await ref.read(authServiceProvider).logout();
  }
}

/// The primary provider for session timeout state.
///
/// Consumers watch this to react to [SessionState.locked] and redirect to the
/// login screen.
final sessionTimeoutProvider =
    NotifierProvider<SessionTimeoutNotifier, SessionState>(
  SessionTimeoutNotifier.new,
);
