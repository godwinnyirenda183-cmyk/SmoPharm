import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pharmacy_pos/data/repositories/stock_in_repository_impl.dart';
import 'package:pharmacy_pos/providers/database_provider.dart';

/// Provides a [StockInRepositoryImpl] backed by the app database.
final stockInRepositoryProvider = Provider<StockInRepositoryImpl>((ref) {
  final db = ref.watch(databaseProvider);
  return StockInRepositoryImpl(db);
});
