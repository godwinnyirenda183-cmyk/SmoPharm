/// Abstract repository for application configuration (key-value store).
abstract class SettingsRepository {
  // ---------------------------------------------------------------------------
  // Generic access
  // ---------------------------------------------------------------------------

  /// Returns the raw string value for [key], or null if not set.
  Future<String?> get(String key);

  /// Persists [value] for [key].
  Future<void> set(String key, String value);

  // ---------------------------------------------------------------------------
  // Typed helpers
  // ---------------------------------------------------------------------------

  /// Returns the pharmacy name, or an empty string if not configured.
  Future<String> getPharmacyName();
  Future<void> setPharmacyName(String name);

  /// Returns the pharmacy address, or an empty string if not configured.
  Future<String> getPharmacyAddress();
  Future<void> setPharmacyAddress(String address);

  /// Returns the pharmacy phone number, or an empty string if not configured.
  Future<String> getPharmacyPhone();
  Future<void> setPharmacyPhone(String phone);

  /// Returns the near-expiry window in days (default: 90).
  Future<int> getNearExpiryWindowDays();

  /// Sets the near-expiry window in days.
  /// Throws [ArgumentError] if [days] is not in the range [1, 365].
  Future<void> setNearExpiryWindowDays(int days);
}
