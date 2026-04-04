// Feature: pharmacy-pos, Property 27: Unique Product Identifiers
//
// Validates: Requirements 1.6
//
// Property 27: For any number of products created, all assigned identifiers
// SHALL be distinct.

import 'package:drift/native.dart';
import 'package:glados/glados.dart';
// Hide Drift-generated Product to avoid conflict with domain entity.
import 'package:pharmacy_pos/database/database.dart' hide Product;
import 'package:pharmacy_pos/data/repositories/product_repository_impl.dart';
import 'package:pharmacy_pos/domain/entities/product.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

AppDatabase _openTestDb() => AppDatabase.forTesting(NativeDatabase.memory());

/// Creates a product with the given [name] and returns it.
Future<Product> _seedProduct(ProductRepositoryImpl repo, String name) =>
    repo.create(ProductInput(
      name: name,
      genericName: '${name}Generic',
      category: 'General',
      unitOfMeasure: 'Tablet',
      sellingPrice: 500,
      lowStockThreshold: 10,
    ));

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

/// Minimum 100 iterations as required by the testing strategy.
final _exploreConfig = ExploreConfig(numRuns: 100);

/// Generates a count N in the range [2, 20] representing the number of
/// products to create.
final _genCount = any.intInRange(2, 21);

// ---------------------------------------------------------------------------
// Property tests
// ---------------------------------------------------------------------------

void main() {
  group('Property 27: Unique Product Identifiers', () {
    // -------------------------------------------------------------------------
    // Sub-property A: All IDs are distinct across N created products
    //
    // For any N in [2, 20], creating N products SHALL result in N distinct
    // non-empty string identifiers with no duplicates.
    // -------------------------------------------------------------------------
    Glados(_genCount, _exploreConfig).test(
      'all assigned product IDs are distinct for any number of products created',
      (count) async {
        final db = _openTestDb();
        try {
          final repo = ProductRepositoryImpl(db);

          // Create `count` products and collect their IDs.
          final ids = <String>[];
          for (var i = 0; i < count; i++) {
            final product = await _seedProduct(repo, 'Product$i');
            ids.add(product.id);
          }

          // All IDs must be non-empty strings.
          for (final id in ids) {
            expect(
              id.isNotEmpty,
              isTrue,
              reason: 'Product ID must be a non-empty string, but got: "$id"',
            );
          }

          // All IDs must be distinct — the set size must equal the list size.
          final uniqueIds = ids.toSet();
          expect(
            uniqueIds.length,
            equals(ids.length),
            reason:
                'Expected $count distinct product IDs but found '
                '${uniqueIds.length} unique values among $ids',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Sub-property B: IDs returned by listAll() are also all distinct
    //
    // After creating N products, the IDs retrieved via listAll() SHALL also
    // be distinct, confirming persistence does not introduce duplicates.
    // -------------------------------------------------------------------------
    Glados(_genCount, _exploreConfig).test(
      'IDs retrieved via listAll() are all distinct after creating N products',
      (count) async {
        final db = _openTestDb();
        try {
          final repo = ProductRepositoryImpl(db);

          for (var i = 0; i < count; i++) {
            await _seedProduct(repo, 'Item$i');
          }

          final all = await repo.listAll();
          final retrievedIds = all.map((p) => p.product.id).toList();

          // All retrieved IDs must be non-empty.
          for (final id in retrievedIds) {
            expect(
              id.isNotEmpty,
              isTrue,
              reason:
                  'Retrieved product ID must be non-empty, but got: "$id"',
            );
          }

          // All retrieved IDs must be distinct.
          final uniqueIds = retrievedIds.toSet();
          expect(
            uniqueIds.length,
            equals(retrievedIds.length),
            reason:
                'Expected ${retrievedIds.length} distinct IDs from listAll() '
                'but found ${uniqueIds.length} unique values',
          );
        } finally {
          await db.close();
        }
      },
    );
  });
}
