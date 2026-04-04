// Feature: pharmacy-pos, Property 20: Conflict Resolution Favours Latest Timestamp
//
// Validates: Requirements 8.5

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_pos/data/services/conflict_resolver.dart';
import 'package:pharmacy_pos/data/services/offline_queue_service.dart';
import 'package:pharmacy_pos/data/services/sync_service_impl.dart';
import 'package:pharmacy_pos/database/database.dart' as db_lib;

db_lib.AppDatabase _openTestDb() =>
    db_lib.AppDatabase.forTesting(NativeDatabase.memory());

void main() {
  // ---------------------------------------------------------------------------
  // ConflictResolver unit tests
  // ---------------------------------------------------------------------------

  group('ConflictResolver', () {
    late db_lib.AppDatabase db;
    late ConflictResolver resolver;

    final now = DateTime(2024, 6, 1, 12, 0, 0);
    final earlier = now.subtract(const Duration(hours: 1));
    final later = now.add(const Duration(hours: 1));

    setUp(() {
      db = _openTestDb();
      resolver = ConflictResolver(db);
    });

    tearDown(() async {
      await db.close();
    });

    // -------------------------------------------------------------------------
    // 1. Local wins when local_updated_at > remote_updated_at
    // -------------------------------------------------------------------------

    test('local wins when localUpdatedAt is later than remoteUpdatedAt',
        () async {
      final result = await resolver.resolve(
        entityType: 'sale',
        entityId: 'sale-1',
        localPayload: '{"id":"sale-1","version":"local"}',
        remotePayload: '{"id":"sale-1","version":"remote"}',
        localUpdatedAt: later,
        remoteUpdatedAt: earlier,
      );

      expect(result.winner, equals('local'));
      expect(result.winningPayload, contains('"version":"local"'));
    });

    // -------------------------------------------------------------------------
    // 2. Remote wins when remote_updated_at > local_updated_at
    // -------------------------------------------------------------------------

    test('remote wins when remoteUpdatedAt is later than localUpdatedAt',
        () async {
      final result = await resolver.resolve(
        entityType: 'product',
        entityId: 'prod-1',
        localPayload: '{"id":"prod-1","version":"local"}',
        remotePayload: '{"id":"prod-1","version":"remote"}',
        localUpdatedAt: earlier,
        remoteUpdatedAt: later,
      );

      expect(result.winner, equals('remote'));
      expect(result.winningPayload, contains('"version":"remote"'));
    });

    // -------------------------------------------------------------------------
    // 3. Conflict is logged to the SyncConflicts table
    // -------------------------------------------------------------------------

    test('conflict is logged to the SyncConflicts table', () async {
      await resolver.resolve(
        entityType: 'stock_adjustment',
        entityId: 'adj-1',
        localPayload: '{"id":"adj-1","local":true}',
        remotePayload: '{"id":"adj-1","local":false}',
        localUpdatedAt: later,
        remoteUpdatedAt: earlier,
      );

      final rows = await db.select(db.syncConflicts).get();
      expect(rows, hasLength(1));

      final row = rows.first;
      expect(row.entityType, equals('stock_adjustment'));
      expect(row.entityId, equals('adj-1'));
    });

    // -------------------------------------------------------------------------
    // 4. Conflict log includes both payloads and the winner
    // -------------------------------------------------------------------------

    test('conflict log includes both payloads and the winner', () async {
      const localJson = '{"id":"sale-2","version":"local"}';
      const remoteJson = '{"id":"sale-2","version":"remote"}';

      await resolver.resolve(
        entityType: 'sale',
        entityId: 'sale-2',
        localPayload: localJson,
        remotePayload: remoteJson,
        localUpdatedAt: earlier,
        remoteUpdatedAt: later,
      );

      final rows = await db.select(db.syncConflicts).get();
      expect(rows, hasLength(1));

      final row = rows.first;
      expect(row.localPayloadJson, equals(localJson));
      expect(row.remotePayloadJson, equals(remoteJson));
      expect(row.winner, equals('remote'));
      expect(row.localUpdatedAt, equals(earlier));
      expect(row.remoteUpdatedAt, equals(later));
    });

    // -------------------------------------------------------------------------
    // 5. Multiple conflicts are each logged as separate rows
    // -------------------------------------------------------------------------

    test('each conflict resolution creates a separate log entry', () async {
      await resolver.resolve(
        entityType: 'sale',
        entityId: 'sale-a',
        localPayload: '{"id":"sale-a"}',
        remotePayload: '{"id":"sale-a","r":1}',
        localUpdatedAt: later,
        remoteUpdatedAt: earlier,
      );
      await resolver.resolve(
        entityType: 'sale',
        entityId: 'sale-b',
        localPayload: '{"id":"sale-b"}',
        remotePayload: '{"id":"sale-b","r":1}',
        localUpdatedAt: earlier,
        remoteUpdatedAt: later,
      );

      final rows = await db.select(db.syncConflicts).get();
      expect(rows, hasLength(2));
      expect(rows.map((r) => r.entityId), containsAll(['sale-a', 'sale-b']));
    });
  });

  // ---------------------------------------------------------------------------
  // SyncServiceImpl — ConflictException integration
  // ---------------------------------------------------------------------------

  group('SyncServiceImpl conflict handling', () {
    late db_lib.AppDatabase db;
    late OfflineQueueService queueService;
    late ConflictResolver conflictResolver;
    late StreamController<List<ConnectivityResult>> connectivityController;

    final remoteUpdatedAt = DateTime(2024, 6, 1, 14, 0, 0);

    setUp(() {
      db = _openTestDb();
      queueService = OfflineQueueService(db);
      conflictResolver = ConflictResolver(db);
      connectivityController =
          StreamController<List<ConnectivityResult>>.broadcast();
    });

    tearDown(() async {
      await connectivityController.close();
      await db.close();
    });

    SyncServiceImpl buildService({required EntryUploader uploader}) {
      return SyncServiceImpl(
        queueService: queueService,
        uploader: uploader,
        conflictResolver: conflictResolver,
        connectivityStream: connectivityController.stream,
      );
    }

    void goOnline() =>
        connectivityController.add([ConnectivityResult.wifi]);

    // -------------------------------------------------------------------------
    // 6. ConflictException is handled: entry is marked synced and conflict logged
    // -------------------------------------------------------------------------

    test(
        'ConflictException from uploader logs conflict and marks entry synced',
        () async {
      await queueService.enqueue(
        entityType: 'sale',
        entityId: 'sale-conflict',
        operation: 'INSERT',
        payloadJson: '{"id":"sale-conflict","version":"local"}',
      );

      final service = buildService(
        uploader: (_) async => throw ConflictException(
          remotePayload: '{"id":"sale-conflict","version":"remote"}',
          remoteUpdatedAt: remoteUpdatedAt,
        ),
      );

      goOnline();
      await Future<void>.delayed(Duration.zero);
      await service.syncNow();

      // Entry should be marked synced (conflict was resolved).
      final unsynced = await queueService.listUnsynced();
      expect(unsynced, isEmpty,
          reason: 'Conflicted entry should be marked synced after resolution');

      // Conflict should be logged.
      final conflicts = await db.select(db.syncConflicts).get();
      expect(conflicts, hasLength(1));
      expect(conflicts.first.entityId, equals('sale-conflict'));
      expect(conflicts.first.localPayloadJson,
          contains('"version":"local"'));
      expect(conflicts.first.remotePayloadJson,
          contains('"version":"remote"'));

      await service.dispose();
    });
  });
}
