import 'package:drift/drift.dart';
import 'package:pharmacy_pos/database/database.dart';
import 'package:pharmacy_pos/domain/entities/offline_queue_entry.dart';
import 'package:uuid/uuid.dart';

/// Service for managing the local offline queue.
///
/// Every transaction (sale, stock-in, stock-adjustment) writes an entry here
/// so that it can be synced to the remote store when connectivity is restored.
class OfflineQueueService {
  final AppDatabase _db;
  final Uuid _uuid;

  OfflineQueueService(this._db, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  // ---------------------------------------------------------------------------
  // enqueue
  // ---------------------------------------------------------------------------

  /// Inserts a new [OfflineQueue] entry with [synced] = false.
  ///
  /// [entityType] — e.g. `'sale'`, `'stock_in'`, `'stock_adjustment'`
  /// [entityId]   — the primary key of the entity being queued
  /// [operation]  — e.g. `'INSERT'`
  /// [payloadJson] — JSON-encoded representation of the entity
  Future<OfflineQueueEntry> enqueue({
    required String entityType,
    required String entityId,
    required String operation,
    required String payloadJson,
  }) async {
    final id = _uuid.v4();
    final now = DateTime.now();

    await _db.into(_db.offlineQueue).insert(
          OfflineQueueCompanion.insert(
            id: id,
            entityType: entityType,
            entityId: entityId,
            operation: operation,
            payloadJson: payloadJson,
            queuedAt: Value(now),
            synced: const Value(false),
          ),
        );

    return OfflineQueueEntry(
      id: id,
      entityType: entityType,
      entityId: entityId,
      operation: QueueOperation.insert,
      payloadJson: payloadJson,
      queuedAt: now,
      synced: false,
    );
  }

  // ---------------------------------------------------------------------------
  // listUnsynced
  // ---------------------------------------------------------------------------

  /// Returns all queue entries where [synced] = false.
  Future<List<OfflineQueueEntry>> listUnsynced() async {
    final rows = await (_db.select(_db.offlineQueue)
          ..where((q) => q.synced.equals(false)))
        .get();

    return rows.map(_rowToEntity).toList();
  }

  // ---------------------------------------------------------------------------
  // markSynced
  // ---------------------------------------------------------------------------

  /// Sets [synced] = true for the entry with the given [id].
  Future<void> markSynced(String id) async {
    await (_db.update(_db.offlineQueue)..where((q) => q.id.equals(id)))
        .write(const OfflineQueueCompanion(synced: Value(true)));
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  OfflineQueueEntry _rowToEntity(OfflineQueueData row) {
    return OfflineQueueEntry(
      id: row.id,
      entityType: row.entityType,
      entityId: row.entityId,
      operation: _operationFromString(row.operation),
      payloadJson: row.payloadJson,
      queuedAt: row.queuedAt,
      synced: row.synced,
    );
  }

  QueueOperation _operationFromString(String s) {
    switch (s.toUpperCase()) {
      case 'UPDATE':
        return QueueOperation.update;
      case 'DELETE':
        return QueueOperation.delete;
      default:
        return QueueOperation.insert;
    }
  }
}
