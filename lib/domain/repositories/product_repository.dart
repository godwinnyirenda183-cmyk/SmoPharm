import '../entities/product.dart';

/// Abstract repository for product CRUD operations.
abstract class ProductRepository {
  /// Creates a new product and returns the persisted entity.
  Future<Product> create(ProductInput input);

  /// Updates an existing product by [id] and returns the updated entity.
  Future<Product> update(String id, ProductInput input);

  /// Deletes a product by [id].
  /// Throws [StateError] if the product has associated batches or sale records.
  Future<void> delete(String id);

  /// Returns all products whose [name] or [genericName] contains [query]
  /// (case-insensitive).
  Future<List<Product>> search(String query);

  /// Returns all products with their computed current stock level.
  Future<List<ProductWithStock>> listAll();

  /// Returns products where stock_level <= low_stock_threshold,
  /// sorted by (stock_level / low_stock_threshold) ascending (most critical first).
  /// Products with a threshold of 0 are treated as ratio 0.0.
  Future<List<ProductWithStock>> listLowStock();
}
