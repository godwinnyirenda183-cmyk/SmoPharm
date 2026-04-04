import 'package:drift/drift.dart';
// Hide the Drift-generated Product data class to avoid conflict with the
// domain entity of the same name.
import 'package:pharmacy_pos/database/database.dart' hide Product;
import 'package:pharmacy_pos/domain/entities/product.dart';
import 'package:pharmacy_pos/domain/repositories/product_repository.dart';
import 'package:uuid/uuid.dart';

/// Concrete implementation of [ProductRepository] backed by the Drift
/// [AppDatabase].
class ProductRepositoryImpl implements ProductRepository {
  final AppDatabase _db;
  final Uuid _uuid;

  ProductRepositoryImpl(this._db, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  // ---------------------------------------------------------------------------
  // create
  // ---------------------------------------------------------------------------

  @override
  Future<Product> create(ProductInput input) async {
    final id = _uuid.v4();
    final now = DateTime.now();

    await _db.into(_db.products).insert(
          ProductsCompanion.insert(
            id: id,
            name: input.name,
            genericName: input.genericName,
            category: input.category,
            unitOfMeasure: input.unitOfMeasure,
            sellingPrice: input.sellingPrice,
            lowStockThreshold: input.lowStockThreshold,
            createdAt: Value(now),
            updatedAt: Value(now),
          ),
        );

    return Product(
      id: id,
      name: input.name,
      genericName: input.genericName,
      category: input.category,
      unitOfMeasure: input.unitOfMeasure,
      sellingPrice: input.sellingPrice,
      lowStockThreshold: input.lowStockThreshold,
      createdAt: now,
      updatedAt: now,
    );
  }

  // ---------------------------------------------------------------------------
  // update
  // ---------------------------------------------------------------------------

  @override
  Future<Product> update(String id, ProductInput input) async {
    final now = DateTime.now();

    await (_db.update(_db.products)..where((p) => p.id.equals(id))).write(
      ProductsCompanion(
        name: Value(input.name),
        genericName: Value(input.genericName),
        category: Value(input.category),
        unitOfMeasure: Value(input.unitOfMeasure),
        sellingPrice: Value(input.sellingPrice),
        lowStockThreshold: Value(input.lowStockThreshold),
        updatedAt: Value(now),
      ),
    );

    final row = await (_db.select(_db.products)
          ..where((p) => p.id.equals(id)))
        .getSingle();

    return _rowToEntity(row);
  }

  // ---------------------------------------------------------------------------
  // delete
  // ---------------------------------------------------------------------------

  @override
  Future<void> delete(String id) async {
    // Check for associated Batch records.
    final batchCount = await (_db.select(_db.batches)
          ..where((b) => b.productId.equals(id)))
        .get()
        .then((rows) => rows.length);

    if (batchCount > 0) {
      throw StateError(
          'Cannot delete product with existing batches or sales');
    }

    // Check for associated SaleItem records.
    final saleItemCount = await (_db.select(_db.saleItems)
          ..where((s) => s.productId.equals(id)))
        .get()
        .then((rows) => rows.length);

    if (saleItemCount > 0) {
      throw StateError(
          'Cannot delete product with existing batches or sales');
    }

    await (_db.delete(_db.products)..where((p) => p.id.equals(id))).go();
  }

  // ---------------------------------------------------------------------------
  // search
  // ---------------------------------------------------------------------------

  @override
  Future<List<Product>> search(String query) async {
    final pattern = '%${query.toLowerCase()}%';

    final rows = await (_db.select(_db.products)
          ..where(
            (p) =>
                p.name.lower().like(pattern) |
                p.genericName.lower().like(pattern),
          ))
        .get();

    return rows.map(_rowToEntity).toList();
  }

  // ---------------------------------------------------------------------------
  // listAll
  // ---------------------------------------------------------------------------

  @override
  Future<List<ProductWithStock>> listAll() async {
    // Fetch all products.
    final productRows = await _db.select(_db.products).get();

    // For each product, compute stock level = SUM(quantity_remaining) of
    // non-expired batches.
    final result = <ProductWithStock>[];

    for (final row in productRows) {
      final batches = await (_db.select(_db.batches)
            ..where(
              (b) =>
                  b.productId.equals(row.id) &
                  b.status.isNotIn(const ['expired']),
            ))
          .get();

      final stockLevel =
          batches.fold<int>(0, (sum, b) => sum + b.quantityRemaining);

      result.add(ProductWithStock(
        product: _rowToEntity(row),
        stockLevel: stockLevel,
      ));
    }

    return result;
  }

  // ---------------------------------------------------------------------------
  // listLowStock
  // ---------------------------------------------------------------------------

  @override
  Future<List<ProductWithStock>> listLowStock() async {
    final all = await listAll();

    // Filter: stock_level <= low_stock_threshold
    final lowStock = all
        .where((p) => p.stockLevel <= p.product.lowStockThreshold)
        .toList();

    // Sort by (stock_level / low_stock_threshold) ascending.
    // Threshold == 0 is treated as ratio 0.0 (most critical).
    lowStock.sort((a, b) {
      final ratioA = a.product.lowStockThreshold == 0
          ? 0.0
          : a.stockLevel.toDouble() / a.product.lowStockThreshold.toDouble();
      final ratioB = b.product.lowStockThreshold == 0
          ? 0.0
          : b.stockLevel.toDouble() / b.product.lowStockThreshold.toDouble();
      return ratioA.compareTo(ratioB);
    });

    return lowStock;
  }

  // ---------------------------------------------------------------------------
  // Helper
  // ---------------------------------------------------------------------------

  Product _rowToEntity(dynamic row) {
    return Product(
      id: row.id as String,
      name: row.name as String,
      genericName: row.genericName as String,
      category: row.category as String,
      unitOfMeasure: row.unitOfMeasure as String,
      sellingPrice: row.sellingPrice as int,
      lowStockThreshold: row.lowStockThreshold as int,
      createdAt: row.createdAt as DateTime,
      updatedAt: row.updatedAt as DateTime,
    );
  }
}
