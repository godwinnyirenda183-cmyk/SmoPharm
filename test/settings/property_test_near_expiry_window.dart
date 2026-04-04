// Feature: pharmacy-pos, Property 4: Near-Expiry Window Validation
//
// Validates: Requirements 2.6, 10.2
//
// Property 4: For any integer value outside the range [1, 365], setting the
// Near_Expiry_Window SHALL be rejected. For any integer value within [1, 365],
// it SHALL be accepted and persisted.

import 'package:drift/native.dart';
import 'package:glados/glados.dart';
import 'package:pharmacy_pos/data/repositories/settings_repository_impl.dart';
import 'package:pharmacy_pos/database/database.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

AppDatabase _openTestDb() => AppDatabase.forTesting(NativeDatabase.memory());

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

/// Generates integers in the valid range [1, 365] (both inclusive).
/// intInRange(min, max): min inclusive, max exclusive → intInRange(1, 366).
final _genValidWindow = any.intInRange(1, 366);

/// Generates integers strictly less than 1 (i.e., 0 and all negatives).
/// intInRange(null, 1): unbounded lower, upper exclusive → values ≤ 0.
final _genInvalidLow = any.intInRange(null, 1);

/// Generates integers strictly greater than 365 (i.e., 366 and above).
/// intInRange(366, null): lower inclusive, unbounded upper → values ≥ 366.
final _genInvalidHigh = any.intInRange(366, null);

// ---------------------------------------------------------------------------
// Property tests
// ---------------------------------------------------------------------------

/// Minimum 100 iterations as required by the testing strategy.
final _exploreConfig = ExploreConfig(numRuns: 100);

void main() {
  group('Property 4: Near-Expiry Window Validation', () {
    // -------------------------------------------------------------------------
    // Sub-property A: Valid values [1, 365] are accepted and persisted
    // -------------------------------------------------------------------------
    Glados(_genValidWindow, _exploreConfig).test(
      'any integer in [1, 365] is accepted and persisted by setNearExpiryWindowDays',
      (days) async {
        final db = _openTestDb();
        try {
          final repo = SettingsRepositoryImpl(db);

          // Should not throw
          await repo.setNearExpiryWindowDays(days);

          // Should return the same value
          final stored = await repo.getNearExpiryWindowDays();
          expect(stored, equals(days),
              reason: 'getNearExpiryWindowDays must return the persisted value $days');
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Sub-property B: Values < 1 are rejected with ArgumentError
    // -------------------------------------------------------------------------
    Glados(_genInvalidLow, _exploreConfig).test(
      'any integer < 1 is rejected by setNearExpiryWindowDays with ArgumentError',
      (days) async {
        final db = _openTestDb();
        try {
          final repo = SettingsRepositoryImpl(db);

          expect(
            () => repo.setNearExpiryWindowDays(days),
            throwsA(isA<ArgumentError>()),
            reason: 'setNearExpiryWindowDays($days) must throw ArgumentError for value < 1',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Sub-property C: Values > 365 are rejected with ArgumentError
    // -------------------------------------------------------------------------
    Glados(_genInvalidHigh, _exploreConfig).test(
      'any integer > 365 is rejected by setNearExpiryWindowDays with ArgumentError',
      (days) async {
        final db = _openTestDb();
        try {
          final repo = SettingsRepositoryImpl(db);

          expect(
            () => repo.setNearExpiryWindowDays(days),
            throwsA(isA<ArgumentError>()),
            reason: 'setNearExpiryWindowDays($days) must throw ArgumentError for value > 365',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Sub-property D: Rejected values do not alter the previously stored value
    // -------------------------------------------------------------------------
    Glados2(_genValidWindow, _genInvalidLow, _exploreConfig).test(
      'a rejected value (< 1) does not overwrite a previously valid setting',
      (validDays, invalidDays) async {
        final db = _openTestDb();
        try {
          final repo = SettingsRepositoryImpl(db);

          // Set a valid value first
          await repo.setNearExpiryWindowDays(validDays);

          // Attempt to set an invalid value — must throw
          try {
            await repo.setNearExpiryWindowDays(invalidDays);
          } on ArgumentError {
            // expected
          }

          // The stored value must remain unchanged
          final stored = await repo.getNearExpiryWindowDays();
          expect(stored, equals(validDays),
              reason: 'Stored value must remain $validDays after rejected attempt with $invalidDays');
        } finally {
          await db.close();
        }
      },
    );

    Glados2(_genValidWindow, _genInvalidHigh, _exploreConfig).test(
      'a rejected value (> 365) does not overwrite a previously valid setting',
      (validDays, invalidDays) async {
        final db = _openTestDb();
        try {
          final repo = SettingsRepositoryImpl(db);

          // Set a valid value first
          await repo.setNearExpiryWindowDays(validDays);

          // Attempt to set an invalid value — must throw
          try {
            await repo.setNearExpiryWindowDays(invalidDays);
          } on ArgumentError {
            // expected
          }

          // The stored value must remain unchanged
          final stored = await repo.getNearExpiryWindowDays();
          expect(stored, equals(validDays),
              reason: 'Stored value must remain $validDays after rejected attempt with $invalidDays');
        } finally {
          await db.close();
        }
      },
    );
  });
}
