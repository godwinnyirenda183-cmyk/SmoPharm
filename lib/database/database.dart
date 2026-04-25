import 'package:bcrypt/bcrypt.dart';
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
  /// When true, the default admin seed is skipped.
  /// Set to true in test databases so tests can insert their own users freely.
  final bool _skipSeed;

  AppDatabase() : _skipSeed = false, super(_openConnection());

  /// Used in tests — pass an in-memory executor directly.
  /// Seeding is skipped so tests can insert their own fixtures without
  /// username uniqueness conflicts.
  AppDatabase.forTesting(super.executor) : _skipSeed = true;

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();

          // Seed default settings.
          await into(settings).insertOnConflictUpdate(
            SettingsCompanion.insert(
              key: 'near_expiry_window_days',
              value: '90',
            ),
          );

          // Seed default admin user for production databases only.
          // Default credentials: username=admin  password=admin123
          // Change the password immediately after first login.
          if (!_skipSeed) {
            final passwordHash = BCrypt.hashpw(
              'admin123',
              BCrypt.gensalt(logRounds: 12),
            );
            await into(users).insert(
              UsersCompanion.insert(
                id: 'seed-admin-001',
                username: 'admin',
                passwordHash: passwordHash,
                role: 'admin',
              ),
            );
          }
        },
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.createTable(syncConflicts);
          }
          if (from < 3) {
            // Add nullable barcode column to products.
            await m.addColumn(products, products.barcode);
          }
        },
      );
}

QueryExecutor _openConnection() {
  return driftDatabase(name: 'pharmacy_pos');
}
