/// Represents the current sync / connectivity status.
enum SyncStatus {
  /// Device is online and queue is empty.
  idle,

  /// Device is online and a sync is in progress.
  syncing,

  /// Device is offline; transactions are being queued locally.
  offline,

  /// The last sync completed successfully.
  syncComplete,

  /// The last sync encountered an error.
  syncError,
}

/// Abstract service for managing the offline queue and syncing to the remote
/// data store.
abstract class SyncService {
  /// Stream of sync/connectivity status changes for UI display.
  Stream<SyncStatus> get statusStream;

  /// Triggers an immediate sync attempt.
  /// No-op if the device is offline.
  Future<void> syncNow();
}
