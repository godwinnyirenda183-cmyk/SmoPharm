/// Domain entity for a single settings key-value pair.
class Settings {
  final String key;
  final String value;

  const Settings({required this.key, required this.value});
}

/// Well-known settings keys used throughout the application.
abstract class SettingsKeys {
  static const String pharmacyName = 'pharmacy_name';
  static const String pharmacyAddress = 'pharmacy_address';
  static const String pharmacyPhone = 'pharmacy_phone';
  static const String nearExpiryWindowDays = 'near_expiry_window_days';
}
