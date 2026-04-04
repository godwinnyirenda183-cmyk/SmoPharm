/// Operations that can be queued for remote sync.
enum QueueOperation { insert, update, delete }

/// Domain entity representing a pending sync entry in the offline queue.
class OfflineQueueEntry {
  final String id;
  final String entityType;
  final String entityId;
  final QueueOperation operation;
  final String payloadJson;
  final DateTime queuedAt;
  final bool synced;

  const OfflineQueueEntry({
    required this.id,
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.payloadJson,
    required this.queuedAt,
    required this.synced,
  });
}
