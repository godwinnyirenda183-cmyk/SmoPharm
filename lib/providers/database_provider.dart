import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pharmacy_pos/database/database.dart';

/// Provides the single [AppDatabase] instance for the entire app.
/// Disposed when the [ProviderScope] is disposed (app shutdown).
final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});
