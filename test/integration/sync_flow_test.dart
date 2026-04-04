// Feature: pharmacy-pos, Integration: Sync Flow
//
// Integration tests for the offline → sync flow.
//
// These tests exercise the full stack from [OfflineQueueService] through
// [SyncServiceImpl] using an in-memory Drift database and a fake connectivity
// stream, so no real network or Supabase connection is required.

import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_pos/data/services/offline_queue_service.dart';
import 'package:pharmacy_pos/data/services/sync_service_impl.dart';
import 'package:pharmacy_pos/database/database.dart' as db_lib;
import 'package:pharmacy_pos/domain/services/sync_service.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

db_lib.AppDatabase _openTestDb() =>
    db_lib.AppDatabase.forTesting(NativeDatabase.memory());

/// Builds a [SyncServiceImpl] wired to [queueService] and [connectivityCtrl].
SyncServiceImpl _buildSyncService({
  required OfflineQueueService queueService,
  required StreamController<List<ConnectivityResult>> connectivityCtrl,
  required EntryUploader uploader,
  db_lib.AppDatabase? db,
}) {
  return SyncServiceImpl(
    queueService: queueService,
    uploader: uploader,
    connectivityStream: connectivityCtrl.stream,
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('Sync flow integration', () {
    late db_lib.AppDatabase db;
    late OfflineQueueService queueService;
    late StreamController<List<ConnectivityResult>> connectivityCtrl;

    setUp(() {
      db = _openTestDb();
      queueService = OfflineQueueService(db);
      connectivityCtrl =
          StreamController<List<ConnectivityResult>>.broadcast();
    });

    tearDown(() async {
      await connectivityCtrl.close();
      await db.close();
    });

    void goOnline() =>
        connectivityCtrl.add([ConnectivityResult.wifi]);
    void goOffline() =>
        connectivityCtrl.add([ConnectivityResult.none]);

    // -----------------------------------------------------------------------
    // 1. Queue captures entries while offline
    // -----------------------------------------------------------------------

    test('entries are captured in the queue while offline', () async {
      final uploaded = <String>[];
      final service = _buildSyncService(
        queueService: queueService,
        connectivityCtrl: connectivityCtrl,
        uploader: (entry) async => uploaded.add(entry.entityId),
      );

      // Start offline — no uploads should happen.
      goOffline();
      await Future<void>.delayed(Duration.zero);

      await queueService.enqueue(
        entityType: 'sale',
        entityId: 'sale-offline-1',
        operation: 'INSERT',
        payloadJson: jsonEncode({'id': 'sale-offline-1', 'total': 5000}),
      );
      await queueService.enqueue(
        entityType: 'stock_in',
        entityId: 'si-offline-1',
        operation: 'INSERT',
        payloadJson: jsonEncode({'id': 'si-offline-1'}),
      );

      // Nothing uploaded yet.
      expect(uploaded, isEmpty);

      // Queue should hold both entries.
      final unsynced = await queueService.listUnsynced();
      expect(unsynced, hasLength(2));

      await service.dispose();
    });

    // -----------------------------------------------------------------------
    // 2. Reconnect triggers auto-sync and clears the queue
    // -----------------------------------------------------------------------

    test('reconnecting triggers auto-sync and clears the queue', () async {
      await queueService.enqueue(
        entityType: 'sale',
        entityId: 'sale-reconnect-1',
        operation: 'INSERT',
        payloadJson: jsonEncode({'id': 'sale-reconnect-1'}),
      );
      await queueService.enqueue(
        entityType: 'stock_adjustment',
        entityId: 'adj-reconnect-1',
        operation: 'INSERT',
        payloadJson: jsonEncode({'id': 'adj-reconnect-1'}),
      );

      final uploaded = <String>[];
      final service = _buildSyncService(
        queueService: queueService,
        connectivityCtrl: connectivityCtrl,
        uploader: (entry) async => uploaded.add(entry.entityId),
      );

      // Start offline.
      goOffline();
      await Future<void>.delayed(Duration.zero);

      // Restore connectivity — auto-sync should fire.
      goOnline();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(uploaded, containsAll(['sale-reconnect-1', 'adj-reconnect-1']));

      final unsynced = await queueService.listUnsynced();
      expect(unsynced, isEmpty,
          reason: 'Queue should be empty after successful sync');

      await service.dispose();
    });

    // -----------------------------------------------------------------------
    // 3. Status stream reflects offline → syncing → syncComplete transitions
    // -----------------------------------------------------------------------

    test('status stream transitions: offline → syncing → syncComplete',
        () async {
      await queueService.enqueue(
        entityType: 'sale',
        entityId: 'sale-status-1',
        operation: 'INSERT',
        payloadJson: '{}',
      );

      final statuses = <SyncStatus>[];
      final service = _buildSyncService(
        queueService: queueService,
        connectivityCtrl: connectivityCtrl,
        uploader: (_) async {},
      );
      final sub = service.statusStream.listen(statuses.add);

      goOffline();
      await Future<void>.delayed(Duration.zero);

      goOnline();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await sub.cancel();
      await service.dispose();

      expect(statuses, containsAllInOrder([SyncStatus.offline]));
      expect(
        statuses,
        containsAllInOrder([SyncStatus.syncing, SyncStatus.syncComplete]),
      );
    });

    // -----------------------------------------------------------------------
    // 4. Entries queued while offline are uploaded after reconnect
    // -----------------------------------------------------------------------

    test('entries queued while offline are uploaded after reconnect', () async {
      final uploaded = <String>[];
      final service = _buildSyncService(
        queueService: queueService,
        connectivityCtrl: connectivityCtrl,
        uploader: (entry) async => uploaded.add(entry.entityId),
      );

      // Go offline, enqueue, then reconnect.
      goOffline();
      await Future<void>.delayed(Duration.zero);

      await queueService.enqueue(
        entityType: 'sale',
        entityId: 'sale-late-1',
        operation: 'INSERT',
        payloadJson: jsonEncode({'id': 'sale-late-1', 'total': 1200}),
      );
      await queueService.enqueue(
        entityType: 'sale',
        entityId: 'sale-late-2',
        operation: 'INSERT',
        payloadJson: jsonEncode({'id': 'sale-late-2', 'total': 800}),
      );

      expect(uploaded, isEmpty, reason: 'No uploads while offline');

      goOnline();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(uploaded, containsAll(['sale-late-1', 'sale-late-2']));

      final unsynced = await queueService.listUnsynced();
      expect(unsynced, isEmpty);

      await service.dispose();
    });

    // -----------------------------------------------------------------------
    // 5. Failed upload leaves entry in queue for retry
    // -----------------------------------------------------------------------

    test('failed upload leaves entry unsynced for retry', () async {
      await queueService.enqueue(
        entityType: 'sale',
        entityId: 'sale-fail-1',
        operation: 'INSERT',
        payloadJson: '{}',
      );

      final service = _buildSyncService(
        queueService: queueService,
        connectivityCtrl: connectivityCtrl,
        uploader: (_) async => throw Exception('network error'),
      );

      goOnline();
      await Future<void>.delayed(Duration.zero);
      await service.syncNow();

      final unsynced = await queueService.listUnsynced();
      expect(unsynced, hasLength(1),
          reason: 'Failed entry must remain in queue');
      expect(unsynced.first.entityId, equals('sale-fail-1'));

      await service.dispose();
    });

    // -----------------------------------------------------------------------
    // 6. Multiple offline/online cycles — queue accumulates then drains
    // -----------------------------------------------------------------------

    test('queue accumulates across multiple offline periods then drains',
        () async {
      final uploaded = <String>[];
      final service = _buildSyncService(
        queueService: queueService,
        connectivityCtrl: connectivityCtrl,
        uploader: (entry) async => uploaded.add(entry.entityId),
      );

      // First offline period.
      goOffline();
      await Future<void>.delayed(Duration.zero);
      await queueService.enqueue(
        entityType: 'sale',
        entityId: 'sale-cycle-1',
        operation: 'INSERT',
        payloadJson: '{}',
      );

      // Reconnect — drains first batch.
      goOnline();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(uploaded, contains('sale-cycle-1'));

      // Second offline period.
      goOffline();
      await Future<void>.delayed(Duration.zero);
      await queueService.enqueue(
        entityType: 'sale',
        entityId: 'sale-cycle-2',
        operation: 'INSERT',
        payloadJson: '{}',
      );

      // Reconnect again — drains second batch.
      goOnline();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(uploaded, containsAll(['sale-cycle-1', 'sale-cycle-2']));

      final unsynced = await queueService.listUnsynced();
      expect(unsynced, isEmpty);

      await service.dispose();
    });

    // -----------------------------------------------------------------------
    // 7. syncNow is a no-op when offline
    // -----------------------------------------------------------------------

    test('syncNow does nothing when offline', () async {
      await queueService.enqueue(
        entityType: 'sale',
        entityId: 'sale-noop-1',
        operation: 'INSERT',
        payloadJson: '{}',
      );

      final uploaded = <String>[];
      final service = _buildSyncService(
        queueService: queueService,
        connectivityCtrl: connectivityCtrl,
        uploader: (entry) async => uploaded.add(entry.entityId),
      );

      goOffline();
      await Future<void>.delayed(Duration.zero);

      // Explicit syncNow while offline should be a no-op.
      await service.syncNow();

      expect(uploaded, isEmpty);
      final unsynced = await queueService.listUnsynced();
      expect(unsynced, hasLength(1));

      await service.dispose();
    });
  });
}
