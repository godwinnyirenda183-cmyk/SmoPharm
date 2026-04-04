import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pharmacy_pos/data/services/sync_service_impl.dart';
import 'package:pharmacy_pos/domain/entities/offline_queue_entry.dart';

/// Maps [OfflineQueueEntry.entityType] to the corresponding Supabase table name.
String _tableForEntityType(String entityType) {
  switch (entityType) {
    case 'sale':
      return 'sales';
    case 'stock_in':
      return 'stock_ins';
    case 'stock_adjustment':
      return 'stock_adjustments';
    default:
      throw ArgumentError('Unknown entity type: $entityType');
  }
}

/// Uploads a single [OfflineQueueEntry] to the appropriate Supabase table.
///
/// - Parses [entry.payloadJson] and upserts it into the table determined by
///   [entry.entityType].
/// - Throws [ConflictException] if Supabase returns a conflict (HTTP 409).
/// - Throws [ArgumentError] if the entity type is not recognised.
///
/// This function is the production [EntryUploader] wired into [SyncServiceImpl].
Future<void> supabaseEntryUploader(OfflineQueueEntry entry) async {
  final tableName = _tableForEntityType(entry.entityType);
  final payload = jsonDecode(entry.payloadJson) as Map<String, dynamic>;

  try {
    await Supabase.instance.client.from(tableName).upsert(payload);
  } on PostgrestException catch (e) {
    // Supabase returns a 23505 (unique violation) or similar conflict codes.
    // HTTP-level 409 surfaces as a PostgrestException with code '23505' or
    // statusCode '409'.
    final code = e.code ?? '';
    final status = e.details?.toString() ?? '';
    if (code == '23505' || code == '409' || status.contains('409')) {
      // Extract remote payload and updated_at from the error details if
      // available; fall back to sensible defaults so ConflictResolver can
      // still log the event.
      throw ConflictException(
        remotePayload: e.message,
        remoteUpdatedAt: DateTime.now(),
      );
    }
    rethrow;
  }
}
