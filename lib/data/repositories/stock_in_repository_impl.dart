import 'dart:convert';

import 'package:drift/drift.dart' hide Batch;
import 'package:pharmacy_pos/data/repositories/batch_repository_impl.dart';
import 'package:pharmacy_pos/data/services/offline_queue_service.dart';
import 'package:pharmacy_pos/database/database.dart' hide StockIn, StockInLine;
import 'package:pharmacy_pos/domain/entities/batch.dart';
import 'package:pharmacy_pos/domain/entities/stock_in.dart';
import 'package:pharmacy_pos/domain/repositories/stock_in_repository.dart';
import 'package:uuid/uuid.dart';

/// Concrete implementation of [StockInRepository] backed by the Drift
/// [AppDatabase].
class StockInRepositoryImpl implements StockInRepository {
  final AppDatabase _db;
  final BatchRepositoryImpl _batchRepo;
  final Uuid _uuid;
  final OfflineQueueService _offlineQueue;

  StockInRepositoryImpl(
    this._db, {
    BatchRepositoryImpl? batchRepo,
    Uuid? uuid,
    int nearExpiryWindowDays = 90,
    OfflineQueueService? offlineQueue,
  })  : _batchRepo = batchRepo ?? BatchRepositoryImpl(_db),
        _uuid = uuid ?? const Uuid(),
        _nearExpiryWindowDays = nearExpiryWindowDays,
        _offlineQueue = offlineQueue ?? OfflineQueueService(_db);

  final int _nearExpiryWindowDays;

  @override
  Future<StockIn> create(StockInCreateInput input) async {
    // Validate all quantities > 0 before touching the DB.
    for (final b in input.batches) {
      if (b.quantity <= 0) {
        throw ArgumentError('Quantity must be greater than zero');
      }
    }

    final stockInId = _uuid.v4();
    final now = DateTime.now();

    // Insert the StockIn header record.
    await _db.into(_db.stockIns).insert(
          StockInsCompanion.insert(
            id: stockInId,
            userId: input.userId,
            recordedAt: Value(now),
          ),
        );

    final lines = <StockInLine>[];

    for (final batchEntry in input.batches) {
      // Create the Batch record via BatchRepositoryImpl.
      final batch = await _batchRepo.create(
        batchEntry.batchInput,
        nearExpiryWindowDays: _nearExpiryWindowDays,
      );

      // Create the StockInLine record linking the StockIn to the Batch.
      final lineId = _uuid.v4();
      await _db.into(_db.stockInLines).insert(
            StockInLinesCompanion.insert(
              id: lineId,
              stockInId: stockInId,
              batchId: batch.id,
              quantity: batchEntry.quantity,
            ),
          );

      lines.add(StockInLine(
        id: lineId,
        stockInId: stockInId,
        batchId: batch.id,
        quantity: batchEntry.quantity,
      ));
    }

    final stockIn = StockIn(
      id: stockInId,
      userId: input.userId,
      recordedAt: now,
      lines: lines,
    );

    // Enqueue for offline sync.
    await _offlineQueue.enqueue(
      entityType: 'stock_in',
      entityId: stockInId,
      operation: 'INSERT',
      payloadJson: jsonEncode({
        'id': stockInId,
        'userId': input.userId,
        'recordedAt': now.toIso8601String(),
        'lines': lines
            .map((l) => {
                  'id': l.id,
                  'stockInId': l.stockInId,
                  'batchId': l.batchId,
                  'quantity': l.quantity,
                })
            .toList(),
      }),
    );

    return stockIn;
  }
}
