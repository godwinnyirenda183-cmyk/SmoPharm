import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:pharmacy_pos/data/services/conflict_resolver.dart';
import 'package:pharmacy_pos/data/services/offline_queue_service.dart';
import 'package:pharmacy_pos/domain/entities/offline_queue_entry.dart';
import 'package:pharmacy_pos/domain/services/sync_service.dart';

/// Thrown by an [EntryUploader] when the remote store detects a conflict
/// (i.e. the same record was modified on two devices).
///
/// The uploader must supply both the [remotePayload] and [remoteUpdatedAt]
/// so that [SyncServiceImpl] can delegate to [ConflictResolver].
class ConflictException implements Exception {
  final String remotePayload;
  final DateTime remoteUpdatedAt;

  const ConflictException({
    required this.remotePayload,
    required this.remoteUpdatedAt,
  });
}

/// Callback type for uploading a single [OfflineQueueEntry] to the remote
/// store.  Returns normally on success; throws [ConflictException] on a
/// conflict; throws any other exception on a general failure.
typedef EntryUploader = Future<void> Function(OfflineQueueEntry entry);

/// Concrete implementation of [SyncService].
///
/// - Monitors connectivity via `connectivity_plus`.
/// - Automatically calls [syncNow] when connectivity is restored.
/// - Uploads queued entries via the injected [EntryUploader] (mockable for
///   tests; in production this calls Supabase).
/// - On [ConflictException], delegates to [ConflictResolver] to retain the
///   latest-timestamp version and log the conflict.
/// - Exposes [statusStream] so the UI can display an offline/sync indicator.
class SyncServiceImpl implements SyncService {
  final OfflineQueueService _queueService;
  final EntryUploader _uploader;
  final ConflictResolver? _conflictResolver;

  /// The connectivity change stream.  Injected so tests can provide a fake.
  final Stream<List<ConnectivityResult>> _connectivityStream;

  final StreamController<SyncStatus> _statusController =
      StreamController<SyncStatus>.broadcast();

  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  bool _isOnline = false;

  SyncServiceImpl({
    required OfflineQueueService queueService,
    required EntryUploader uploader,
    ConflictResolver? conflictResolver,
    Stream<List<ConnectivityResult>>? connectivityStream,
  })  : _queueService = queueService,
        _uploader = uploader,
        _conflictResolver = conflictResolver,
        _connectivityStream =
            connectivityStream ?? Connectivity().onConnectivityChanged {
    _init();
  }

  // ---------------------------------------------------------------------------
  // SyncService interface
  // ---------------------------------------------------------------------------

  @override
  Stream<SyncStatus> get statusStream => _statusController.stream;

  @override
  Future<void> syncNow() async {
    if (!_isOnline) return;

    _emit(SyncStatus.syncing);

    try {
      final unsynced = await _queueService.listUnsynced();

      for (final entry in unsynced) {
        await _uploadEntry(entry);
        await _queueService.markSynced(entry.id);
      }

      _emit(SyncStatus.syncComplete);
    } catch (_) {
      _emit(SyncStatus.syncError);
    }
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  void _init() {
    _connectivitySubscription =
        _connectivityStream.listen(_onConnectivityChanged);
  }

  /// Disposes resources.  Call this when the service is no longer needed.
  Future<void> dispose() async {
    await _connectivitySubscription?.cancel();
    await _statusController.close();
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Uploads a single queue entry, handling [ConflictException] by delegating
  /// to [ConflictResolver] when one is provided.
  Future<void> _uploadEntry(OfflineQueueEntry entry) async {
    try {
      await _uploader(entry);
    } on ConflictException catch (e) {
      if (_conflictResolver != null) {
        // Parse the local updated_at from the payload if available; fall back
        // to the queue timestamp.
        final localUpdatedAt = entry.queuedAt;
        await _conflictResolver.resolve(
          entityType: entry.entityType,
          entityId: entry.entityId,
          localPayload: entry.payloadJson,
          remotePayload: e.remotePayload,
          localUpdatedAt: localUpdatedAt,
          remoteUpdatedAt: e.remoteUpdatedAt,
        );
        // Conflict is resolved and logged; mark the entry as synced so it
        // is not retried.
      } else {
        rethrow;
      }
    }
  }

  void _onConnectivityChanged(List<ConnectivityResult> results) {
    final wasOnline = _isOnline;
    _isOnline = results.any((r) => r != ConnectivityResult.none);

    if (_isOnline) {
      if (!wasOnline) {
        // Connectivity just restored — auto-sync.
        syncNow();
      } else {
        _emit(SyncStatus.idle);
      }
    } else {
      _emit(SyncStatus.offline);
    }
  }

  void _emit(SyncStatus status) {
    if (!_statusController.isClosed) {
      _statusController.add(status);
    }
  }
}
