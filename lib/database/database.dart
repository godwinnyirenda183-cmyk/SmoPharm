import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:pharmacy_pos/database/tables.dart';

part 'database.g.dart';

@DriftDatabase(
  tables: [
    Users,
    Products,
    Batches,
    StockIns,
    StockInLines,
    StockAdjustments,
    Sales,
    SaleItems,
    OfflineQueue,
    Settings,
    SyncConflicts,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  /// Used in tests — pass an in-memory executor directly.
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          // Seed default settings
          await into(settings).insertOnConflictUpdate(
            SettingsCompanion.insert(
              key: 'near_expiry_window_days',
              value: '90',
            ),
          );
        },
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.createTable(syncConflicts);
          }
        },
      );
}

QueryExecutor _openConnection() {
  return driftDatabase(name: 'pharmacy_pos');
}
