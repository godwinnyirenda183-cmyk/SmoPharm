import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_pos/data/services/offline_queue_service.dart';
import 'package:pharmacy_pos/data/services/sync_service_impl.dart';
import 'package:pharmacy_pos/database/database.dart' as db_lib;
import 'package:pharmacy_pos/domain/entities/offline_queue_entry.dart';
import 'package:pharmacy_pos/domain/services/sync_service.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

db_lib.AppDatabase _openTestDb() =>
    db_lib.AppDatabase.forTesting(NativeDatabase.memory());

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('SyncServiceImpl', () {
    late db_lib.AppDatabase db;
    late OfflineQueueService queueService;
    late StreamController<List<ConnectivityResult>> connectivityController;

    setUp(() {
      db = _openTestDb();
      queueService = OfflineQueueService(db);
      connectivityController =
          StreamController<List<ConnectivityResult>>.broadcast();
    });

    tearDown(() async {
      await connectivityController.close();
      await db.close();
    });

    // -------------------------------------------------------------------------
    // Helper to build a SyncServiceImpl with a custom uploader
    // -------------------------------------------------------------------------
    SyncServiceImpl buildService({required EntryUploader uploader}) {
      return SyncServiceImpl(
        queueService: queueService,
        uploader: uploader,
        connectivityStream: connectivityController.stream,
      );
    }

    void goOnline() =>
        connectivityController.add([ConnectivityResult.wifi]);
    void goOffline() =>
        connectivityController.add([ConnectivityResult.none]);

    // -------------------------------------------------------------------------
    // 1. syncNow marks entries as synced after successful upload
    // -------------------------------------------------------------------------

    test('syncNow marks entries as synced after successful upload', () async {
      await queueService.enqueue(
        entityType: 'sale',
        entityId: 'sale-1',
        operation: 'INSERT',
        payloadJson: '{"id":"sale-1"}',
      );
      await queueService.enqueue(
        entityType: 'sale',
        entityId: 'sale-2',
        operation: 'INSERT',
        payloadJson: '{"id":"sale-2"}',
      );

      final uploaded = <String>[];
      final service = buildService(
        uploader: (entry) async => uploaded.add(entry.entityId),
      );

      // Go online so _isOnline = true, then call syncNow explicitly.
      goOnline();
      await Future<void>.delayed(Duration.zero);
      await service.syncNow();

      final unsynced = await queueService.listUnsynced();
      expect(unsynced, isEmpty,
          reason: 'All entries should be marked synced');
      expect(uploaded, containsAll(['sale-1', 'sale-2']));

      await service.dispose();
    });

    // -------------------------------------------------------------------------
    // 2. syncNow emits syncing then syncComplete status
    // -------------------------------------------------------------------------

    test('syncNow emits syncing then syncComplete', () async {
      await queueService.enqueue(
        entityType: 'sale',
        entityId: 'sale-x',
        operation: 'INSERT',
        payloadJson: '{}',
      );

      final statuses = <SyncStatus>[];
      final service = buildService(uploader: (_) async {});
      final sub = service.statusStream.listen(statuses.add);

      goOnline();
      await Future<void>.delayed(Duration.zero);
      await service.syncNow();

      await sub.cancel();
      await service.dispose();

      expect(
        statuses,
        containsAllInOrder([SyncStatus.syncing, SyncStatus.syncComplete]),
      );
    });

    // -------------------------------------------------------------------------
    // 3. Offline status is emitted when connectivity is lost
    // -------------------------------------------------------------------------

    test('emits offline status when connectivity is lost', () async {
      final statuses = <SyncStatus>[];
      final service = buildService(uploader: (_) async {});
      final sub = service.statusStream.listen(statuses.add);

      goOffline();
      await Future<void>.delayed(Duration.zero);

      await sub.cancel();
      await service.dispose();

      expect(statuses, contains(SyncStatus.offline));
    });

    // -------------------------------------------------------------------------
    // 4. Failed upload does not mark entry as synced
    // -------------------------------------------------------------------------

    test('failed upload does not mark entry as synced', () async {
      await queueService.enqueue(
        entityType: 'sale',
        entityId: 'sale-fail',
        operation: 'INSERT',
        payloadJson: '{}',
      );

      final service = buildService(
        uploader: (_) async => throw Exception('network error'),
      );

      goOnline();
      await Future<void>.delayed(Duration.zero);
      await service.syncNow();

      final unsynced = await queueService.listUnsynced();
      expect(unsynced, hasLength(1),
          reason: 'Entry should remain unsynced after upload failure');
      expect(unsynced.first.entityId, equals('sale-fail'));

      await service.dispose();
    });

    // -------------------------------------------------------------------------
    // 5. syncNow emits syncError on upload failure
    // -------------------------------------------------------------------------

    test('syncNow emits syncError when upload fails', () async {
      await queueService.enqueue(
        entityType: 'sale',
        entityId: 'sale-err',
        operation: 'INSERT',
        payloadJson: '{}',
      );

      final statuses = <SyncStatus>[];
      final service = buildService(
        uploader: (_) async => throw Exception('upload failed'),
      );
      final sub = service.statusStream.listen(statuses.add);

      goOnline();
      await Future<void>.delayed(Duration.zero);
      await service.syncNow();

      await sub.cancel();
      await service.dispose();

      expect(statuses, contains(SyncStatus.syncError));
    });

    // -------------------------------------------------------------------------
    // 6. Auto-sync triggers on reconnect
    // -------------------------------------------------------------------------

    test('auto-syncs when connectivity is restored', () async {
      await queueService.enqueue(
        entityType: 'stock_in',
        entityId: 'si-1',
        operation: 'INSERT',
        payloadJson: '{}',
      );

      final uploaded = <String>[];
      final service = buildService(
        uploader: (entry) async => uploaded.add(entry.entityId),
      );

      // Start offline, then go online.
      goOffline();
      await Future<void>.delayed(Duration.zero);

      goOnline();
      // Allow the auto-sync triggered by reconnect to complete.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(uploaded, contains('si-1'),
          reason: 'Auto-sync should upload queued entries on reconnect');

      await service.dispose();
    });
  });
}
