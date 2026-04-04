// Feature: pharmacy-pos, Property 19: Sync Clears Queue
//
// Validates: Requirements 8.4
//
// Property 19: For any set of Offline_Queue entries that are successfully
// uploaded to the remote store, all such entries SHALL be marked as synced
// and excluded from subsequent sync attempts.
//
// This test verifies:
//   1. For any N entries in the queue, after a successful sync,
//      listUnsynced() returns 0 entries.
//   2. For any N entries, after a successful sync, all N entries have
//      synced=true in the DB.
//   3. Failed entries are NOT cleared from the queue (remain unsynced).

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/native.dart';
import 'package:glados/glados.dart';
import 'package:pharmacy_pos/data/services/offline_queue_service.dart';
import 'package:pharmacy_pos/data/services/sync_service_impl.dart';
import 'package:pharmacy_pos/database/database.dart' as db_lib;
import 'package:pharmacy_pos/domain/entities/offline_queue_entry.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

db_lib.AppDatabase _openTestDb() =>
    db_lib.AppDatabase.forTesting(NativeDatabase.memory());

/// Enqueues [n] distinct sale entries and returns their ids.
Future<List<String>> _enqueueN(OfflineQueueService queueService, int n) async {
  final ids = <String>[];
  for (var i = 0; i < n; i++) {
    final entry = await queueService.enqueue(
      entityType: 'sale',
      entityId: 'sale-$i',
      operation: 'INSERT',
      payloadJson: '{"id":"sale-$i"}',
    );
    ids.add(entry.id);
  }
  return ids;
}

/// Reads all rows from the offline queue (synced and unsynced) and returns
/// a map of id → synced.
Future<Map<String, bool>> _allSyncedStates(db_lib.AppDatabase db) async {
  final rows = await db.select(db.offlineQueue).get();
  return {for (final r in rows) r.id: r.synced};
}

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

/// Minimum 100 iterations as required by the testing strategy.
final _exploreConfig = ExploreConfig(numRuns: 100);

/// Generates N in [1, 10].
final _genN = any.intInRange(1, 11);

// ---------------------------------------------------------------------------
// Property tests
// ---------------------------------------------------------------------------

void main() {
  group('Property 19: Sync Clears Queue', () {
    // -------------------------------------------------------------------------
    // Property 19a: For any N entries, after a successful sync,
    // listUnsynced() returns 0 entries.
    //
    // Strategy:
    //   1. Generate N in [1, 10].
    //   2. Enqueue N entries (all unsynced).
    //   3. Run syncNow() with a no-op uploader (all uploads succeed).
    //   4. Assert listUnsynced() returns an empty list.
    // -------------------------------------------------------------------------
    Glados(_genN, _exploreConfig).test(
      'after successful sync of N entries, listUnsynced() returns 0 entries',
      (n) async {
        final db = _openTestDb();
        final connectivityController =
            StreamController<List<ConnectivityResult>>.broadcast();
        try {
          final queueService = OfflineQueueService(db);
          await _enqueueN(queueService, n);

          final service = SyncServiceImpl(
            queueService: queueService,
            uploader: (_) async {}, // always succeeds
            connectivityStream: connectivityController.stream,
          );

          // Go online so _isOnline = true.
          connectivityController.add([ConnectivityResult.wifi]);
          await Future<void>.delayed(Duration.zero);

          await service.syncNow();

          final unsynced = await queueService.listUnsynced();

          expect(
            unsynced,
            isEmpty,
            reason:
                'After successful sync of $n entries, listUnsynced() should '
                'return 0 entries but returned ${unsynced.length}.',
          );

          await service.dispose();
        } finally {
          await connectivityController.close();
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Property 19b: For any N entries, after a successful sync, all N entries
    // have synced=true in the DB.
    //
    // Strategy:
    //   1. Generate N in [1, 10].
    //   2. Enqueue N entries.
    //   3. Run syncNow() with a no-op uploader.
    //   4. Read all rows from the DB and assert every row has synced=true.
    // -------------------------------------------------------------------------
    Glados(_genN, _exploreConfig).test(
      'after successful sync of N entries, all N rows have synced=true in DB',
      (n) async {
        final db = _openTestDb();
        final connectivityController =
            StreamController<List<ConnectivityResult>>.broadcast();
        try {
          final queueService = OfflineQueueService(db);
          final enqueuedIds = await _enqueueN(queueService, n);

          final service = SyncServiceImpl(
            queueService: queueService,
            uploader: (_) async {}, // always succeeds
            connectivityStream: connectivityController.stream,
          );

          connectivityController.add([ConnectivityResult.wifi]);
          await Future<void>.delayed(Duration.zero);

          await service.syncNow();

          final syncedStates = await _allSyncedStates(db);

          for (final id in enqueuedIds) {
            expect(
              syncedStates[id],
              isTrue,
              reason:
                  'Entry $id should have synced=true after successful sync.',
            );
          }

          await service.dispose();
        } finally {
          await connectivityController.close();
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Property 19c: Failed entries are NOT cleared from the queue.
    //
    // Strategy:
    //   1. Generate N in [1, 10].
    //   2. Enqueue N entries.
    //   3. Run syncNow() with an uploader that always throws (all uploads fail).
    //   4. Assert listUnsynced() still returns N entries (none cleared).
    //   5. Assert all N entries still have synced=false in the DB.
    // -------------------------------------------------------------------------
    Glados(_genN, _exploreConfig).test(
      'failed entries remain unsynced after a failed sync attempt',
      (n) async {
        final db = _openTestDb();
        final connectivityController =
            StreamController<List<ConnectivityResult>>.broadcast();
        try {
          final queueService = OfflineQueueService(db);
          final enqueuedIds = await _enqueueN(queueService, n);

          final service = SyncServiceImpl(
            queueService: queueService,
            uploader: (_) async =>
                throw Exception('simulated upload failure'),
            connectivityStream: connectivityController.stream,
          );

          connectivityController.add([ConnectivityResult.wifi]);
          await Future<void>.delayed(Duration.zero);

          await service.syncNow();

          final unsynced = await queueService.listUnsynced();

          // All N entries must still be unsynced.
          expect(
            unsynced.length,
            equals(n),
            reason:
                'After a failed sync, all $n entries should remain unsynced '
                'but only ${unsynced.length} remain.',
          );

          // Verify each enqueued entry is still unsynced in the DB.
          final syncedStates = await _allSyncedStates(db);
          for (final id in enqueuedIds) {
            expect(
              syncedStates[id],
              isFalse,
              reason:
                  'Entry $id should still have synced=false after a failed sync.',
            );
          }

          // All remaining entries must have synced=false.
          for (final entry in unsynced) {
            expect(
              entry.synced,
              isFalse,
              reason:
                  'listUnsynced() returned entry ${entry.id} with synced=true.',
            );
          }

          await service.dispose();
        } finally {
          await connectivityController.close();
          await db.close();
        }
      },
    );
  });
}
