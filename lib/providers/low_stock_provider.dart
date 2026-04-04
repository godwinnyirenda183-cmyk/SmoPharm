import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pharmacy_pos/data/repositories/product_repository_impl.dart';
import 'package:pharmacy_pos/domain/entities/product.dart';
import 'package:pharmacy_pos/providers/database_provider.dart';

/// Provides a [ProductRepositoryImpl] backed by the app database.
final productRepositoryProvider = Provider<ProductRepositoryImpl>((ref) {
  final db = ref.watch(databaseProvider);
  return ProductRepositoryImpl(db);
});

/// A [StreamProvider] that emits the current low-stock product list and
/// refreshes every 30 seconds for reactive dashboard updates.
///
/// Drift does not expose a built-in watch for this computed query, so a
/// periodic timer is used to re-fetch and push updates downstream.
final lowStockProvider =
    StreamProvider<List<ProductWithStock>>((ref) async* {
  final repo = ref.watch(productRepositoryProvider);

  // Emit immediately on first subscription.
  yield await repo.listLowStock();

  // Then re-emit every 30 seconds.
  final ticker = Stream<void>.periodic(const Duration(seconds: 30));
  await for (final _ in ticker) {
    yield await repo.listLowStock();
  }
});
