// Feature: pharmacy-pos, Property 24: Product Search Completeness
//
// Validates: Requirements 1.3, 5.1
//
// Property 24: For any search query string q and any set of products, the
// search results SHALL include all products where name or generic_name contains
// q (case-insensitive), and SHALL NOT include products where neither field
// contains q.

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

/// Seeds a product with the given name and generic name, returning the created
/// [Product].
Future<Product> _seedProduct(
  ProductRepositoryImpl repo, {
  required String name,
  required String genericName,
}) =>
    repo.create(ProductInput(
      name: name,
      genericName: genericName,
      category: 'General',
      unitOfMeasure: 'Tablet',
      sellingPrice: 500,
      lowStockThreshold: 10,
    ));

/// Returns true if [query] is a case-insensitive substring of [text].
bool _containsIgnoreCase(String text, String query) =>
    text.toLowerCase().contains(query.toLowerCase());

/// Returns true if a product matches the search query (name OR generic_name).
bool _productMatches(Product p, String query) =>
    _containsIgnoreCase(p.name, query) ||
    _containsIgnoreCase(p.genericName, query);

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

/// Minimum 100 iterations as required by the testing strategy.
final _exploreConfig = ExploreConfig(numRuns: 100);

/// Generates non-empty alphanumeric strings of length 3–12 suitable for
/// product names and generic names.
/// Uses glados letterOrDigits generator (a-z, A-Z, 0-9).
final _genAlphanumeric = any.letterOrDigits.map((s) {
  // Pad to at least 3 chars, then cap at 12.
  final padded = s.padRight(3, 'a');
  return padded.length > 12 ? padded.substring(0, 12) : padded;
});

/// Generates a list of 2–5 alphanumeric strings (for product names).
final _genNameList = any.list(_genAlphanumeric).map((list) {
  if (list.length < 2) return ['alpha', 'beta'];
  if (list.length > 5) return list.sublist(0, 5);
  return list;
});

// ---------------------------------------------------------------------------
// Property tests
// ---------------------------------------------------------------------------

void main() {
  group('Property 24: Product Search Completeness', () {
    // -------------------------------------------------------------------------
    // Sub-property A: All matching products appear in results
    //
    // Strategy: generate a list of product names, pick a substring of the
    // first product's name as the query, insert all products, run search, and
    // verify every product whose name or generic_name contains the query is
    // present in the results.
    // -------------------------------------------------------------------------
    Glados(_genNameList, _exploreConfig).test(
      'every product whose name or generic_name contains q appears in results',
      (names) async {
        final db = _openTestDb();
        try {
          final repo = ProductRepositoryImpl(db);

          // Seed products: name = names[i], genericName = names[i] + 'Gen'
          final products = <Product>[];
          for (final name in names) {
            final p = await _seedProduct(
              repo,
              name: name,
              genericName: '${name}Gen',
            );
            products.add(p);
          }

          // Use a substring of the first product's name as the query.
          // This guarantees at least one match.
          final firstName = names.first;
          // Take the first 2 characters as the query (always a substring).
          final query = firstName.substring(0, firstName.length.clamp(1, 2));

          final results = await repo.search(query);
          final resultIds = results.map((p) => p.id).toSet();

          // Every product that matches the query must be in the results.
          for (final p in products) {
            if (_productMatches(p, query)) {
              expect(
                resultIds.contains(p.id),
                isTrue,
                reason:
                    'Product "${p.name}" (generic: "${p.genericName}") matches '
                    'query "$query" but was not returned by search()',
              );
            }
          }
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Sub-property B: No non-matching products appear in results
    //
    // Strategy: seed a product whose name and generic_name are known to NOT
    // contain the query, run search, and verify that product is absent.
    // -------------------------------------------------------------------------
    Glados2(_genAlphanumeric, _genAlphanumeric, _exploreConfig).test(
      'no product whose name and generic_name both lack q appears in results',
      (matchingName, nonMatchingName) async {
        // We need the non-matching name to be genuinely different from the
        // matching name so we can construct a query that hits one but not the
        // other.  If they happen to be equal, skip this iteration by treating
        // it as a trivial case (both would match the same query).
        if (matchingName == nonMatchingName) return;

        // Build a query that is a prefix of matchingName but is NOT contained
        // in nonMatchingName.  We try prefixes of increasing length until we
        // find one that is absent from nonMatchingName.
        String? query;
        for (var len = 1; len <= matchingName.length; len++) {
          final candidate = matchingName.substring(0, len);
          if (!_containsIgnoreCase(nonMatchingName, candidate) &&
              !_containsIgnoreCase('${nonMatchingName}Gen', candidate)) {
            query = candidate;
            break;
          }
        }

        // If no discriminating prefix exists, skip (both names share all
        // prefixes — e.g. one is a prefix of the other).
        if (query == null) return;

        final db = _openTestDb();
        try {
          final repo = ProductRepositoryImpl(db);

          // Seed the matching product.
          final matching = await _seedProduct(
            repo,
            name: matchingName,
            genericName: '${matchingName}Gen',
          );

          // Seed the non-matching product.
          final nonMatching = await _seedProduct(
            repo,
            name: nonMatchingName,
            genericName: '${nonMatchingName}Gen',
          );

          final results = await repo.search(query);
          final resultIds = results.map((p) => p.id).toSet();

          // The matching product must be present.
          expect(
            resultIds.contains(matching.id),
            isTrue,
            reason:
                'Product "${matching.name}" matches query "$query" but was '
                'not returned by search()',
          );

          // The non-matching product must be absent.
          expect(
            resultIds.contains(nonMatching.id),
            isFalse,
            reason:
                'Product "${nonMatching.name}" does NOT match query "$query" '
                'but was incorrectly returned by search()',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Sub-property C: Empty query returns all products
    //
    // An empty string is a substring of every string, so all products must be
    // returned when q = ''.
    // -------------------------------------------------------------------------
    Glados(_genNameList, _exploreConfig).test(
      'empty query returns all seeded products',
      (names) async {
        final db = _openTestDb();
        try {
          final repo = ProductRepositoryImpl(db);

          final seededIds = <String>{};
          for (final name in names) {
            final p = await _seedProduct(
              repo,
              name: name,
              genericName: '${name}Gen',
            );
            seededIds.add(p.id);
          }

          final results = await repo.search('');
          final resultIds = results.map((p) => p.id).toSet();

          for (final id in seededIds) {
            expect(
              resultIds.contains(id),
              isTrue,
              reason: 'Product $id must appear in results for empty query',
            );
          }
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Sub-property D: Query matching only generic_name returns that product
    //
    // Ensures the OR condition (name OR generic_name) is correctly implemented.
    // -------------------------------------------------------------------------
    Glados2(_genAlphanumeric, _genAlphanumeric, _exploreConfig).test(
      'product matched only by generic_name appears in results',
      (productName, genericName) async {
        // Ensure the product name does NOT contain the generic name prefix so
        // the match is purely via generic_name.
        final query = genericName.substring(0, genericName.length.clamp(1, 2));
        if (_containsIgnoreCase(productName, query)) return; // skip trivial case

        final db = _openTestDb();
        try {
          final repo = ProductRepositoryImpl(db);

          final p = await _seedProduct(
            repo,
            name: productName,
            genericName: genericName,
          );

          final results = await repo.search(query);
          final resultIds = results.map((r) => r.id).toSet();

          expect(
            resultIds.contains(p.id),
            isTrue,
            reason:
                'Product "${p.name}" with genericName "${p.genericName}" '
                'should match query "$query" via generic_name but was absent',
          );
        } finally {
          await db.close();
        }
      },
    );
  });
}
