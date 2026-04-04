import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_pos/data/repositories/settings_repository_impl.dart';
import 'package:pharmacy_pos/database/database.dart';

AppDatabase _openTestDb() => AppDatabase.forTesting(NativeDatabase.memory());

void main() {
  group('SettingsRepositoryImpl', () {
    late AppDatabase db;
    late SettingsRepositoryImpl repo;

    setUp(() {
      db = _openTestDb();
      repo = SettingsRepositoryImpl(db);
    });

    tearDown(() async {
      await db.close();
    });

    // -------------------------------------------------------------------------
    // Pharmacy name
    // -------------------------------------------------------------------------

    test('getPharmacyName returns empty string when not set', () async {
      expect(await repo.getPharmacyName(), equals(''));
    });

    test('setPharmacyName persists and getPharmacyName retrieves it', () async {
      await repo.setPharmacyName('City Pharmacy');
      expect(await repo.getPharmacyName(), equals('City Pharmacy'));
    });

    test('setPharmacyName overwrites previous value', () async {
      await repo.setPharmacyName('Old Name');
      await repo.setPharmacyName('New Name');
      expect(await repo.getPharmacyName(), equals('New Name'));
    });

    // -------------------------------------------------------------------------
    // Pharmacy address
    // -------------------------------------------------------------------------

    test('getPharmacyAddress returns empty string when not set', () async {
      expect(await repo.getPharmacyAddress(), equals(''));
    });

    test('setPharmacyAddress persists and getPharmacyAddress retrieves it',
        () async {
      await repo.setPharmacyAddress('123 Cairo Road, Lusaka');
      expect(
          await repo.getPharmacyAddress(), equals('123 Cairo Road, Lusaka'));
    });

    test('setPharmacyAddress overwrites previous value', () async {
      await repo.setPharmacyAddress('Old Address');
      await repo.setPharmacyAddress('New Address');
      expect(await repo.getPharmacyAddress(), equals('New Address'));
    });

    // -------------------------------------------------------------------------
    // Pharmacy phone
    // -------------------------------------------------------------------------

    test('getPharmacyPhone returns empty string when not set', () async {
      expect(await repo.getPharmacyPhone(), equals(''));
    });

    test('setPharmacyPhone persists and getPharmacyPhone retrieves it',
        () async {
      await repo.setPharmacyPhone('+260 211 123456');
      expect(await repo.getPharmacyPhone(), equals('+260 211 123456'));
    });

    test('setPharmacyPhone overwrites previous value', () async {
      await repo.setPharmacyPhone('0211-111111');
      await repo.setPharmacyPhone('0211-222222');
      expect(await repo.getPharmacyPhone(), equals('0211-222222'));
    });

    // -------------------------------------------------------------------------
    // Near-expiry window — default
    // -------------------------------------------------------------------------

    test('getNearExpiryWindowDays returns 90 by default (seeded in migration)',
        () async {
      // The database migration seeds near_expiry_window_days = '90'.
      expect(await repo.getNearExpiryWindowDays(), equals(90));
    });

    // -------------------------------------------------------------------------
    // Near-expiry window — valid values
    // -------------------------------------------------------------------------

    test('setNearExpiryWindowDays accepts boundary value 1', () async {
      await repo.setNearExpiryWindowDays(1);
      expect(await repo.getNearExpiryWindowDays(), equals(1));
    });

    test('setNearExpiryWindowDays accepts boundary value 365', () async {
      await repo.setNearExpiryWindowDays(365);
      expect(await repo.getNearExpiryWindowDays(), equals(365));
    });

    test('setNearExpiryWindowDays accepts mid-range value', () async {
      await repo.setNearExpiryWindowDays(30);
      expect(await repo.getNearExpiryWindowDays(), equals(30));
    });

    test('setNearExpiryWindowDays overwrites previous value', () async {
      await repo.setNearExpiryWindowDays(60);
      await repo.setNearExpiryWindowDays(120);
      expect(await repo.getNearExpiryWindowDays(), equals(120));
    });

    // -------------------------------------------------------------------------
    // Near-expiry window — invalid values
    // -------------------------------------------------------------------------

    test('setNearExpiryWindowDays rejects 0', () async {
      expect(
        () => repo.setNearExpiryWindowDays(0),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          'Near-expiry window must be between 1 and 365 days',
        )),
      );
    });

    test('setNearExpiryWindowDays rejects negative values', () async {
      expect(
        () => repo.setNearExpiryWindowDays(-10),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('setNearExpiryWindowDays rejects 366', () async {
      expect(
        () => repo.setNearExpiryWindowDays(366),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          'Near-expiry window must be between 1 and 365 days',
        )),
      );
    });

    test('setNearExpiryWindowDays rejects large values', () async {
      expect(
        () => repo.setNearExpiryWindowDays(1000),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejected value does not change the stored setting', () async {
      await repo.setNearExpiryWindowDays(45);
      try {
        await repo.setNearExpiryWindowDays(0);
      } catch (_) {}
      expect(await repo.getNearExpiryWindowDays(), equals(45));
    });

    // -------------------------------------------------------------------------
    // Persistence across repository instances (same DB)
    // -------------------------------------------------------------------------

    test('settings persist across repository instances sharing the same DB',
        () async {
      await repo.setPharmacyName('Shared Pharmacy');
      await repo.setPharmacyAddress('456 Independence Ave');
      await repo.setPharmacyPhone('+260 977 000000');
      await repo.setNearExpiryWindowDays(60);

      // Create a second repository instance pointing at the same DB.
      final repo2 = SettingsRepositoryImpl(db);

      expect(await repo2.getPharmacyName(), equals('Shared Pharmacy'));
      expect(await repo2.getPharmacyAddress(), equals('456 Independence Ave'));
      expect(await repo2.getPharmacyPhone(), equals('+260 977 000000'));
      expect(await repo2.getNearExpiryWindowDays(), equals(60));
    });
  });
}
