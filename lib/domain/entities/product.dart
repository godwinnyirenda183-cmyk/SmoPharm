/// Domain entity for a pharmacy product/medicine.
/// All monetary values are integer cents.
class Product {
  final String id;
  final String name;
  final String genericName;
  final String category;
  final String unitOfMeasure;
  /// Selling price in integer cents (e.g. 1000 = ZMW 10.00).
  final int sellingPrice;
  final int lowStockThreshold;
  /// Optional barcode (EAN-13, EAN-8, Code128, etc.).
  final String? barcode;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Product({
    required this.id,
    required this.name,
    required this.genericName,
    required this.category,
    required this.unitOfMeasure,
    required this.sellingPrice,
    required this.lowStockThreshold,
    this.barcode,
    required this.createdAt,
    required this.updatedAt,
  });
}

/// Product with its computed current stock level.
class ProductWithStock {
  final Product product;
  final int stockLevel;

  const ProductWithStock({required this.product, required this.stockLevel});
}

/// Input DTO for creating or updating a product.
class ProductInput {
  final String name;
  final String genericName;
  final String category;
  final String unitOfMeasure;
  /// Selling price in integer cents.
  final int sellingPrice;
  final int lowStockThreshold;
  /// Optional barcode.
  final String? barcode;

  const ProductInput({
    required this.name,
    required this.genericName,
    required this.category,
    required this.unitOfMeasure,
    required this.sellingPrice,
    required this.lowStockThreshold,
    this.barcode,
  });
}
