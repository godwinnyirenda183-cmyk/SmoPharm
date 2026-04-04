import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pharmacy_pos/data/services/report_service_impl.dart';
import 'package:pharmacy_pos/domain/services/report_service.dart';
import 'package:pharmacy_pos/providers/database_provider.dart';
import 'package:pharmacy_pos/providers/low_stock_provider.dart';

/// Provides a [ReportServiceImpl] backed by the app database.
final reportServiceProvider = Provider<ReportService>((ref) {
  final db = ref.watch(databaseProvider);
  final productRepo = ref.watch(productRepositoryProvider);
  return ReportServiceImpl(db, productRepo);
});
