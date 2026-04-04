import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pharmacy_pos/data/repositories/settings_repository_impl.dart';
import 'package:pharmacy_pos/providers/database_provider.dart';

/// Provides a [SettingsRepositoryImpl] backed by the app database.
final settingsRepositoryProvider = Provider<SettingsRepositoryImpl>((ref) {
  final db = ref.watch(databaseProvider);
  return SettingsRepositoryImpl(db);
});
