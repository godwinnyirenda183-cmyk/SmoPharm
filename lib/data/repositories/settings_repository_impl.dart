import 'package:drift/drift.dart';
import 'package:pharmacy_pos/database/database.dart';
import 'package:pharmacy_pos/domain/entities/settings.dart';
import 'package:pharmacy_pos/domain/repositories/settings_repository.dart';

/// Concrete implementation of [SettingsRepository] backed by the Drift
/// [AppDatabase] Settings table (key-value store).
class SettingsRepositoryImpl implements SettingsRepository {
  final AppDatabase _db;

  SettingsRepositoryImpl(this._db);

  // ---------------------------------------------------------------------------
  // Generic access
  // ---------------------------------------------------------------------------

  @override
  Future<String?> get(String key) async {
    final row = await (_db.select(_db.settings)
          ..where((s) => s.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  @override
  Future<void> set(String key, String value) async {
    await _db.into(_db.settings).insertOnConflictUpdate(
          SettingsCompanion.insert(key: key, value: value),
        );
  }

  // ---------------------------------------------------------------------------
  // Typed helpers — pharmacy info
  // ---------------------------------------------------------------------------

  @override
  Future<String> getPharmacyName() async {
    return await get(SettingsKeys.pharmacyName) ?? '';
  }

  @override
  Future<void> setPharmacyName(String name) async {
    await set(SettingsKeys.pharmacyName, name);
  }

  @override
  Future<String> getPharmacyAddress() async {
    return await get(SettingsKeys.pharmacyAddress) ?? '';
  }

  @override
  Future<void> setPharmacyAddress(String address) async {
    await set(SettingsKeys.pharmacyAddress, address);
  }

  @override
  Future<String> getPharmacyPhone() async {
    return await get(SettingsKeys.pharmacyPhone) ?? '';
  }

  @override
  Future<void> setPharmacyPhone(String phone) async {
    await set(SettingsKeys.pharmacyPhone, phone);
  }

  // ---------------------------------------------------------------------------
  // Typed helpers — near-expiry window
  // ---------------------------------------------------------------------------

  @override
  Future<int> getNearExpiryWindowDays() async {
    final raw = await get(SettingsKeys.nearExpiryWindowDays);
    if (raw == null) return 90;
    return int.tryParse(raw) ?? 90;
  }

  @override
  Future<void> setNearExpiryWindowDays(int days) async {
    if (days < 1 || days > 365) {
      throw ArgumentError(
          'Near-expiry window must be between 1 and 365 days');
    }
    await set(SettingsKeys.nearExpiryWindowDays, days.toString());
  }
}
