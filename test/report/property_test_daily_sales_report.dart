// Feature: pharmacy-pos, Property 15: Daily Sales Report Aggregation
//
// Validates: Requirements 7.1
//
// Property 15: For any date, the Daily Sales Report total revenue SHALL equal
// the sum of total_zmw for all non-voided sales recorded on that date, and
// the transaction count SHALL equal the number of such sales.

import 'package:drift/drift.dart' hide Batch;
import 'package:drift/native.dart';
import 'package:glados/glados.dart';
import 'package:pharmacy_pos/data/repositories/product_repository_impl.dart';
import 'package:pharmacy_pos/data/services/report_service_impl.dart';
import 'package:pharmacy_pos/database/database.dart' as db_lib;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

db_lib.AppDatabase _openTestDb() =>
    db_lib.AppDatabase.forTesting(NativeDatabase.memory());

/// Insert a minimal user row (required by FK).
Future<String> _insertUser(db_lib.AppDatabase db, String suffix) async {
  final id = 'user-p15-$suffix';
  await db.into(db.users).insert(db_lib.UsersCompanion.insert(
        id: id,
        username: 'cashier_p15_$suffix',
        passwordHash: 'hash',
        role: 'cashier',
      ));
  return id;
}

/// Insert a sale row directly with full control over [voided] and [recordedAt].
Future<void> _insertSale(
  db_lib.AppDatabase db, {
  required String id,
  required String userId,
  required DateTime recordedAt,
  required int totalZmw,
  bool voided = false,
}) async {
  await db.into(db.sales).insert(db_lib.SalesCompanion.insert(
        id: id,
        userId: userId,
        recordedAt: Value(recordedAt),
        totalZmw: totalZmw,
        paymentMethod: 'Cash',
        voided: Value(voided),
      ));
}

// ---------------------------------------------------------------------------
// Data class for a generated sale spec
// ---------------------------------------------------------------------------

class _SaleSpec {
  final int totalZmw; // amount in cents [100, 5000]
  final bool voided;

  const _SaleSpec(this.totalZmw, this.voided);

  @override
  String toString() => '_SaleSpec(total=$totalZmw, voided=$voided)';
}

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

/// Minimum 100 iterations as required by the testing strategy.
final _exploreConfig = ExploreConfig(numRuns: 100);

/// Generates a single sale spec: amount in [100, 5000] cents, voided bool.
final _genSaleSpec = any.intInRange(100, 5001).bind(
      (amount) => any.bool.map((v) => _SaleSpec(amount, v)),
    );

/// Generates a list of 1–10 sale specs.
final _genSaleSpecs = any
    .list(_genSaleSpec)
    .map((list) {
      if (list.isEmpty) return [const _SaleSpec(100, false)];
      if (list.length > 10) return list.sublist(0, 10);
      return list;
    });

/// Generates N in [1, 10] non-voided sale amounts in [100, 5000] cents.
final _genNonVoidedAmounts = any
    .list(any.intInRange(100, 5001))
    .map((list) {
      if (list.isEmpty) return [100];
      if (list.length > 10) return list.sublist(0, 10);
      return list;
    });

// ---------------------------------------------------------------------------
// Property tests
// ---------------------------------------------------------------------------

void main() {
  group('Property 15: Daily Sales Report Aggregation', () {
    // -------------------------------------------------------------------------
    // Property A: total revenue equals sum of total_zmw for non-voided sales.
    //
    // Strategy:
    //   1. Generate a list of 1–10 sale specs (amount, voided flag).
    //   2. Insert all sales on a fixed target date.
    //   3. Call dailySalesReport() for that date.
    //   4. Assert totalRevenueCents == sum of amounts for non-voided sales.
    //   5. Assert transactionCount == count of non-voided sales.
    // -------------------------------------------------------------------------
    Glados(_genSaleSpecs, _exploreConfig).test(
      'total revenue equals sum of non-voided sale amounts',
      (specs) async {
        final db = _openTestDb();
        try {
          final productRepo = ProductRepositoryImpl(db);
          final service = ReportServiceImpl(db, productRepo);
          final userId = await _insertUser(db, 'a-${specs.hashCode}');

          // Use a fixed target date to avoid any date-boundary issues.
          final targetDate = DateTime(2024, 3, 15);
          final dayStart = DateTime(2024, 3, 15, 9, 0);

          int expectedRevenue = 0;
          int expectedCount = 0;

          for (var i = 0; i < specs.length; i++) {
            final spec = specs[i];
            await _insertSale(
              db,
              id: 'sale-p15a-${specs.hashCode}-$i',
              userId: userId,
              recordedAt: dayStart.add(Duration(minutes: i)),
              totalZmw: spec.totalZmw,
              voided: spec.voided,
            );
            if (!spec.voided) {
              expectedRevenue += spec.totalZmw;
              expectedCount++;
            }
          }

          final report = await service.dailySalesReport(targetDate);

          expect(
            report.totalRevenueCents,
            equals(expectedRevenue),
            reason:
                'totalRevenueCents should be $expectedRevenue '
                '(sum of non-voided amounts) but got '
                '${report.totalRevenueCents}. specs=$specs',
          );

          expect(
            report.transactionCount,
            equals(expectedCount),
            reason:
                'transactionCount should be $expectedCount '
                '(count of non-voided sales) but got '
                '${report.transactionCount}. specs=$specs',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Property B: N non-voided sales → transaction count equals N and
    //             total revenue equals sum of their amounts.
    //
    // Strategy:
    //   1. Generate a list of 1–10 non-voided amounts.
    //   2. Insert all as non-voided sales on a fixed date.
    //   3. Assert transactionCount == N and totalRevenueCents == sum.
    // -------------------------------------------------------------------------
    Glados(_genNonVoidedAmounts, _exploreConfig).test(
      'N non-voided sales produce transaction count N and correct revenue',
      (amounts) async {
        final db = _openTestDb();
        try {
          final productRepo = ProductRepositoryImpl(db);
          final service = ReportServiceImpl(db, productRepo);
          final userId = await _insertUser(db, 'b-${amounts.hashCode}');

          final targetDate = DateTime(2024, 4, 20);
          final dayStart = DateTime(2024, 4, 20, 10, 0);

          int expectedRevenue = 0;
          for (var i = 0; i < amounts.length; i++) {
            await _insertSale(
              db,
              id: 'sale-p15b-${amounts.hashCode}-$i',
              userId: userId,
              recordedAt: dayStart.add(Duration(minutes: i)),
              totalZmw: amounts[i],
              voided: false,
            );
            expectedRevenue += amounts[i];
          }

          final report = await service.dailySalesReport(targetDate);

          expect(
            report.transactionCount,
            equals(amounts.length),
            reason:
                'transactionCount should equal N=${amounts.length} '
                'but got ${report.transactionCount}. amounts=$amounts',
          );

          expect(
            report.totalRevenueCents,
            equals(expectedRevenue),
            reason:
                'totalRevenueCents should be $expectedRevenue '
                'but got ${report.totalRevenueCents}. amounts=$amounts',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Property C: voided sales are excluded from both revenue and count.
    //
    // Strategy:
    //   1. Generate N in [1, 10] non-voided amounts and M in [1, 5] voided
    //      amounts.
    //   2. Insert all on the same date.
    //   3. Assert voided amounts do not contribute to revenue or count.
    // -------------------------------------------------------------------------
    Glados2(
      _genNonVoidedAmounts,
      any
          .list(any.intInRange(100, 5001))
          .map((list) {
            if (list.isEmpty) return [200];
            if (list.length > 5) return list.sublist(0, 5);
            return list;
          }),
      _exploreConfig,
    ).test(
      'voided sales are excluded from revenue and transaction count',
      (nonVoidedAmounts, voidedAmounts) async {
        final db = _openTestDb();
        try {
          final productRepo = ProductRepositoryImpl(db);
          final service = ReportServiceImpl(db, productRepo);
          final userId = await _insertUser(
              db, 'c-${nonVoidedAmounts.hashCode}-${voidedAmounts.hashCode}');

          final targetDate = DateTime(2024, 5, 10);
          final dayStart = DateTime(2024, 5, 10, 8, 0);

          int expectedRevenue = 0;
          int idx = 0;

          // Insert non-voided sales.
          for (final amount in nonVoidedAmounts) {
            await _insertSale(
              db,
              id: 'sale-p15c-nv-${nonVoidedAmounts.hashCode}-$idx',
              userId: userId,
              recordedAt: dayStart.add(Duration(minutes: idx)),
              totalZmw: amount,
              voided: false,
            );
            expectedRevenue += amount;
            idx++;
          }

          // Insert voided sales — must NOT contribute.
          for (final amount in voidedAmounts) {
            await _insertSale(
              db,
              id: 'sale-p15c-v-${voidedAmounts.hashCode}-$idx',
              userId: userId,
              recordedAt: dayStart.add(Duration(minutes: idx)),
              totalZmw: amount,
              voided: true,
            );
            idx++;
          }

          final report = await service.dailySalesReport(targetDate);

          expect(
            report.totalRevenueCents,
            equals(expectedRevenue),
            reason:
                'totalRevenueCents should be $expectedRevenue '
                '(voided sales excluded) but got '
                '${report.totalRevenueCents}. '
                'nonVoided=$nonVoidedAmounts, voided=$voidedAmounts',
          );

          expect(
            report.transactionCount,
            equals(nonVoidedAmounts.length),
            reason:
                'transactionCount should be ${nonVoidedAmounts.length} '
                '(voided sales excluded) but got '
                '${report.transactionCount}. '
                'nonVoided=$nonVoidedAmounts, voided=$voidedAmounts',
          );
        } finally {
          await db.close();
        }
      },
    );
  });
}
