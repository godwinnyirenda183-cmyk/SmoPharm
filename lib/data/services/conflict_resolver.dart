import 'package:drift/drift.dart';
import 'package:pharmacy_pos/database/database.dart';
import 'package:uuid/uuid.dart';

/// The outcome of a conflict resolution.
class ConflictResolution {
  /// Which version won: `'local'` or `'remote'`.
  final String winner;

  /// The JSON payload of the winning version.
  final String winningPayload;

  const ConflictResolution({
    required this.winner,
    required this.winningPayload,
  });
}

/// Resolves sync conflicts by retaining the record with the later
/// [updated_at] timestamp and logging the conflict to the [SyncConflicts]
/// table for admin review.
///
/// **Property 20: Conflict Resolution Favours Latest Timestamp**
/// For any sync conflict between two versions of the same record, the version
/// with the later `updated_at` timestamp SHALL be retained, and the conflict
/// SHALL be logged.
///
/// **Validates: Requirements 8.5**
class ConflictResolver {
  final AppDatabase _db;
  final Uuid _uuid;

  ConflictResolver(this._db, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  /// Resolves a conflict between [localPayload] and [remotePayload] for the
  /// given [entityType] / [entityId].
  ///
  /// - Compares [localUpdatedAt] vs [remoteUpdatedAt].
  /// - The payload with the later timestamp wins.
  /// - Logs the conflict to the [SyncConflicts] table.
  /// - Returns a [ConflictResolution] describing the winner and winning payload.
  Future<ConflictResolution> resolve({
    required String entityType,
    required String entityId,
    required String localPayload,
    required String remotePayload,
    required DateTime localUpdatedAt,
    required DateTime remoteUpdatedAt,
  }) async {
    final winner =
        localUpdatedAt.isAfter(remoteUpdatedAt) ? 'local' : 'remote';
    final winningPayload =
        winner == 'local' ? localPayload : remotePayload;

    await _db.into(_db.syncConflicts).insert(
          SyncConflictsCompanion.insert(
            id: _uuid.v4(),
            entityType: entityType,
            entityId: entityId,
            localPayloadJson: localPayload,
            remotePayloadJson: remotePayload,
            localUpdatedAt: localUpdatedAt,
            remoteUpdatedAt: remoteUpdatedAt,
            winner: winner,
            resolvedAt: Value(DateTime.now()),
          ),
        );

    return ConflictResolution(winner: winner, winningPayload: winningPayload);
  }
}
