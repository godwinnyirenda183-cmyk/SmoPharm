import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pharmacy_pos/data/repositories/batch_repository_impl.dart';
import 'package:pharmacy_pos/providers/database_provider.dart';

/// Provides a [BatchRepositoryImpl] backed by the app database.
final batchRepositoryProvider = Provider<BatchRepositoryImpl>((ref) {
  final db = ref.watch(databaseProvider);
  return BatchRepositoryImpl(db);
});
