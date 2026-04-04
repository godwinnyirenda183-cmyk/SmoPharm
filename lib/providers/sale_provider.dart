import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pharmacy_pos/data/repositories/sale_repository_impl.dart';
import 'package:pharmacy_pos/providers/database_provider.dart';

/// Provides a [SaleRepositoryImpl] backed by the app database.
final saleRepositoryProvider = Provider<SaleRepositoryImpl>((ref) {
  final db = ref.watch(databaseProvider);
  return SaleRepositoryImpl(db);
});
