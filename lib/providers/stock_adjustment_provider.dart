import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pharmacy_pos/data/repositories/stock_adjustment_repository_impl.dart';
import 'package:pharmacy_pos/providers/database_provider.dart';

/// Provides a [StockAdjustmentRepositoryImpl] backed by the app database.
final stockAdjustmentRepositoryProvider =
    Provider<StockAdjustmentRepositoryImpl>((ref) {
  final db = ref.watch(databaseProvider);
  return StockAdjustmentRepositoryImpl(db);
});
