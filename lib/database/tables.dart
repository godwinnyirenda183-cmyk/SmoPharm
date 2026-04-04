import 'package:drift/drift.dart';

// ---------------------------------------------------------------------------
// USER
// ---------------------------------------------------------------------------
@DataClassName('UserRow')
class Users extends Table {
  TextColumn get id => text()();
  TextColumn get username => text().unique()();
  TextColumn get passwordHash => text()();
  TextColumn get role => text()(); // 'admin' | 'cashier'
  BoolColumn get locked => boolean().withDefault(const Constant(false))();
  IntColumn get failedAttempts => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// PRODUCT
// ---------------------------------------------------------------------------
class Products extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get genericName => text()();
  TextColumn get category => text()();
  TextColumn get unitOfMeasure => text()();
  // Stored as integer cents (e.g. 1000 = ZMW 10.00)
  IntColumn get sellingPrice => integer()();
  IntColumn get lowStockThreshold => integer()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// BATCH
// ---------------------------------------------------------------------------
class Batches extends Table {
  TextColumn get id => text()();
  TextColumn get productId =>
      text().references(Products, #id, onDelete: KeyAction.restrict)();
  TextColumn get batchNumber => text()();
  DateTimeColumn get expiryDate => dateTime()();
  TextColumn get supplierName => text()();
  IntColumn get quantityReceived => integer()();
  IntColumn get quantityRemaining => integer()();
  // Stored as integer cents
  IntColumn get costPricePerUnit => integer()();
  DateTimeColumn get receivedDate => dateTime().withDefault(currentDateAndTime)();
  // 'active' | 'near_expiry' | 'expired'
  TextColumn get status => text().withDefault(const Constant('active'))();

  @override
  Set<Column> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// STOCK_IN
// ---------------------------------------------------------------------------
class StockIns extends Table {
  TextColumn get id => text()();
  TextColumn get userId =>
      text().references(Users, #id, onDelete: KeyAction.restrict)();
  DateTimeColumn get recordedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// STOCK_IN_LINE
// ---------------------------------------------------------------------------
class StockInLines extends Table {
  TextColumn get id => text()();
  TextColumn get stockInId =>
      text().references(StockIns, #id, onDelete: KeyAction.cascade)();
  TextColumn get batchId =>
      text().references(Batches, #id, onDelete: KeyAction.restrict)();
  IntColumn get quantity => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// STOCK_ADJUSTMENT
// ---------------------------------------------------------------------------
class StockAdjustments extends Table {
  TextColumn get id => text()();
  TextColumn get productId =>
      text().references(Products, #id, onDelete: KeyAction.restrict)();
  TextColumn get userId =>
      text().references(Users, #id, onDelete: KeyAction.restrict)();
  // Positive = increase, negative = decrease
  IntColumn get quantityDelta => integer()();
  // 'Damaged' | 'Expired_Removal' | 'Count_Correction' | 'Other'
  TextColumn get reasonCode => text()();
  DateTimeColumn get recordedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// SALE
// ---------------------------------------------------------------------------
class Sales extends Table {
  TextColumn get id => text()();
  TextColumn get userId =>
      text().references(Users, #id, onDelete: KeyAction.restrict)();
  DateTimeColumn get recordedAt => dateTime().withDefault(currentDateAndTime)();
  // Stored as integer cents
  IntColumn get totalZmw => integer()();
  // 'Cash' | 'Mobile_Money' | 'Insurance'
  TextColumn get paymentMethod => text()();
  BoolColumn get voided => boolean().withDefault(const Constant(false))();
  TextColumn get voidReason => text().nullable()();
  DateTimeColumn get voidedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// SALE_ITEM
// ---------------------------------------------------------------------------
class SaleItems extends Table {
  TextColumn get id => text()();
  TextColumn get saleId =>
      text().references(Sales, #id, onDelete: KeyAction.cascade)();
  TextColumn get productId =>
      text().references(Products, #id, onDelete: KeyAction.restrict)();
  TextColumn get batchId =>
      text().references(Batches, #id, onDelete: KeyAction.restrict)();
  IntColumn get quantity => integer()();
  // Stored as integer cents
  IntColumn get unitPrice => integer()();
  // Stored as integer cents
  IntColumn get lineTotal => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// OFFLINE_QUEUE
// ---------------------------------------------------------------------------
class OfflineQueue extends Table {
  TextColumn get id => text()();
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  TextColumn get operation => text()(); // 'INSERT' | 'UPDATE' | 'DELETE'
  TextColumn get payloadJson => text()();
  DateTimeColumn get queuedAt => dateTime().withDefault(currentDateAndTime)();
  BoolColumn get synced => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// SETTINGS
// ---------------------------------------------------------------------------
class Settings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

// ---------------------------------------------------------------------------
// SYNC_CONFLICTS
// ---------------------------------------------------------------------------
@DataClassName('SyncConflictRow')
class SyncConflicts extends Table {
  TextColumn get id => text()();
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  TextColumn get localPayloadJson => text()();
  TextColumn get remotePayloadJson => text()();
  DateTimeColumn get localUpdatedAt => dateTime()();
  DateTimeColumn get remoteUpdatedAt => dateTime()();
  // 'local' | 'remote'
  TextColumn get winner => text()();
  DateTimeColumn get resolvedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}
