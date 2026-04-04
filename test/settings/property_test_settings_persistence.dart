// Feature: pharmacy-pos, Property 25: Settings Persistence Round-Trip
//
// Validates: Requirements 10.1, 10.3
//
// Property 25: For any configuration value saved to settings, re-initialising
// the settings repository (simulating an app restart) SHALL return the same
// value.

import 'package:drift/native.dart';
import 'package:glados/glados.dart';
import 'package:pharmacy_pos/data/repositories/settings_repository_impl.dart';
import 'package:pharmacy_pos/database/database.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Opens a shared in-memory database (same object = same SQLite connection).
AppDatabase _openTestDb() => AppDatabase.forTesting(NativeDatabase.memory());

/// Simulates an "app restart" by constructing a second [SettingsRepositoryImpl]
/// that points to the same [AppDatabase] instance.  Because both instances
/// share the same underlying SQLite connection, any value written by the first
/// instance must be visible to the second — exactly what would happen after a
/// real restart where the DB file is re-opened from disk.
SettingsRepositoryImpl _restart(AppDatabase db) => SettingsRepositoryImpl(db);

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

/// Minimum 100 iterations as required by the testing strategy.
final _exploreConfig = ExploreConfig(numRuns: 100);

/// Generates arbitrary strings suitable for pharmacy name / address / phone.
/// Uses glados letterOrDigits generator (a-z, A-Z, 0-9) which covers the
/// full space of typical pharmacy info values.
final _genString = any.letterOrDigits;

/// Generates valid near-expiry window integers in [1, 365].
final _genValidWindow = any.intInRange(1, 366); // intInRange upper is exclusive

// ---------------------------------------------------------------------------
// Property tests
// ---------------------------------------------------------------------------

void main() {
  group('Property 25: Settings Persistence Round-Trip', () {
    // -------------------------------------------------------------------------
    // Sub-property A: Pharmacy name round-trip
    // -------------------------------------------------------------------------
    Glados(_genString, _exploreConfig).test(
      'any pharmacy name saved by repo1 is returned by repo2 on the same DB',
      (name) async {
        final db = _openTestDb();
        try {
          final repo1 = SettingsRepositoryImpl(db);
          await repo1.setPharmacyName(name);

          // Simulate restart: new instance, same DB object.
          final repo2 = _restart(db);
          final retrieved = await repo2.getPharmacyName();

          expect(
            retrieved,
            equals(name),
            reason: 'getPharmacyName() after restart must return "$name"',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Sub-property B: Pharmacy address round-trip
    // -------------------------------------------------------------------------
    Glados(_genString, _exploreConfig).test(
      'any pharmacy address saved by repo1 is returned by repo2 on the same DB',
      (address) async {
        final db = _openTestDb();
        try {
          final repo1 = SettingsRepositoryImpl(db);
          await repo1.setPharmacyAddress(address);

          final repo2 = _restart(db);
          final retrieved = await repo2.getPharmacyAddress();

          expect(
            retrieved,
            equals(address),
            reason: 'getPharmacyAddress() after restart must return "$address"',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Sub-property C: Pharmacy phone round-trip
    // -------------------------------------------------------------------------
    Glados(_genString, _exploreConfig).test(
      'any pharmacy phone saved by repo1 is returned by repo2 on the same DB',
      (phone) async {
        final db = _openTestDb();
        try {
          final repo1 = SettingsRepositoryImpl(db);
          await repo1.setPharmacyPhone(phone);

          final repo2 = _restart(db);
          final retrieved = await repo2.getPharmacyPhone();

          expect(
            retrieved,
            equals(phone),
            reason: 'getPharmacyPhone() after restart must return "$phone"',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Sub-property D: Near-expiry window round-trip (valid range [1, 365])
    // -------------------------------------------------------------------------
    Glados(_genValidWindow, _exploreConfig).test(
      'any valid near-expiry window saved by repo1 is returned by repo2 on the same DB',
      (days) async {
        final db = _openTestDb();
        try {
          final repo1 = SettingsRepositoryImpl(db);
          await repo1.setNearExpiryWindowDays(days);

          final repo2 = _restart(db);
          final retrieved = await repo2.getNearExpiryWindowDays();

          expect(
            retrieved,
            equals(days),
            reason: 'getNearExpiryWindowDays() after restart must return $days',
          );
        } finally {
          await db.close();
        }
      },
    );
  });
}
