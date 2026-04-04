// Feature: pharmacy-pos, Property 20: Conflict Resolution Favours Latest Timestamp
//
// Validates: Requirements 8.5
//
// Property 20: For any sync conflict between two versions of the same record,
// the version with the later `updated_at` timestamp SHALL be retained, and the
// conflict SHALL be logged.
//
// This test verifies:
//   1. For any two timestamps where local > remote, the winner is 'local'.
//   2. For any two timestamps where remote > local, the winner is 'remote'.
//   3. For any conflict, the conflict is logged to the SyncConflicts table.
//   4. The winning payload matches the version with the later timestamp.
//
// Strategy:
//   - Generate two distinct minute-offsets from a base time (ensuring they differ).
//   - The larger offset → later timestamp; the smaller → earlier timestamp.
//   - Assign local/remote accordingly and verify the winner is always the later one.

import 'package:drift/native.dart';
import 'package:glados/glados.dart';
import 'package:pharmacy_pos/data/services/conflict_resolver.dart';
import 'package:pharmacy_pos/database/database.dart' as db_lib;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

db_lib.AppDatabase _openTestDb() =>
    db_lib.AppDatabase.forTesting(NativeDatabase.memory());

/// Base time used as the anchor for all generated timestamps.
final _baseTime = DateTime(2024, 1, 1, 0, 0, 0, 0, 0);

/// Converts a minute offset to a [DateTime] relative to [_baseTime].
DateTime _offsetToDateTime(int offsetMinutes) =>
    _baseTime.add(Duration(minutes: offsetMinutes));

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

/// Minimum 100 iterations as required by the testing strategy.
final _exploreConfig = ExploreConfig(numRuns: 100);

/// Generates a pair of distinct minute offsets as [baseOffset, delta] where
/// delta is in [1, 1000], guaranteeing baseOffset != baseOffset + delta.
/// The "earlier" timestamp uses baseOffset, the "later" uses baseOffset + delta.
final _genDistinctOffsets = any
    .intInRange(0, 9001)
    .bind((base) => any.intInRange(1, 1001).map((delta) => [base, base + delta]));

// ---------------------------------------------------------------------------
// Property tests
// ---------------------------------------------------------------------------

void main() {
  group('Property 20: Conflict Resolution Favours Latest Timestamp', () {
    // -------------------------------------------------------------------------
    // Property 20a: For any two timestamps where local > remote,
    // the winner is 'local' and the winning payload is the local payload.
    //
    // Strategy:
    //   1. Generate two distinct minute offsets [a, b] where a != b.
    //   2. Assign the larger offset to local (later timestamp) and the
    //      smaller to remote (earlier timestamp).
    //   3. Resolve the conflict.
    //   4. Assert winner == 'local' and winningPayload == localPayload.
    // -------------------------------------------------------------------------
    Glados(_genDistinctOffsets, _exploreConfig).test(
      'local wins when localUpdatedAt is later than remoteUpdatedAt',
      (pair) async {
        final db = _openTestDb();
        try {
          final resolver = ConflictResolver(db);

          // pair[0] = earlier offset, pair[1] = later offset (pair[1] > pair[0]).
          final localUpdatedAt = _offsetToDateTime(pair[1]); // later
          final remoteUpdatedAt = _offsetToDateTime(pair[0]); // earlier

          const localPayload = '{"version":"local","data":"local_data"}';
          const remotePayload = '{"version":"remote","data":"remote_data"}';

          final result = await resolver.resolve(
            entityType: 'product',
            entityId: 'prod-p20a',
            localPayload: localPayload,
            remotePayload: remotePayload,
            localUpdatedAt: localUpdatedAt,
            remoteUpdatedAt: remoteUpdatedAt,
          );

          expect(
            result.winner,
            equals('local'),
            reason:
                'Expected winner=local when localUpdatedAt ($localUpdatedAt) '
                '> remoteUpdatedAt ($remoteUpdatedAt), but got ${result.winner}.',
          );
          expect(
            result.winningPayload,
            equals(localPayload),
            reason:
                'Expected winningPayload to be the local payload when local '
                'timestamp is later.',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Property 20b: For any two timestamps where remote > local,
    // the winner is 'remote' and the winning payload is the remote payload.
    //
    // Strategy:
    //   1. Generate two distinct minute offsets [a, b] where a != b.
    //   2. Assign the larger offset to remote (later timestamp) and the
    //      smaller to local (earlier timestamp).
    //   3. Resolve the conflict.
    //   4. Assert winner == 'remote' and winningPayload == remotePayload.
    // -------------------------------------------------------------------------
    Glados(_genDistinctOffsets, _exploreConfig).test(
      'remote wins when remoteUpdatedAt is later than localUpdatedAt',
      (pair) async {
        final db = _openTestDb();
        try {
          final resolver = ConflictResolver(db);

          // pair[0] = earlier offset, pair[1] = later offset (pair[1] > pair[0]).
          final localUpdatedAt = _offsetToDateTime(pair[0]); // earlier
          final remoteUpdatedAt = _offsetToDateTime(pair[1]); // later

          const localPayload = '{"version":"local","data":"local_data"}';
          const remotePayload = '{"version":"remote","data":"remote_data"}';

          final result = await resolver.resolve(
            entityType: 'sale',
            entityId: 'sale-p20b',
            localPayload: localPayload,
            remotePayload: remotePayload,
            localUpdatedAt: localUpdatedAt,
            remoteUpdatedAt: remoteUpdatedAt,
          );

          expect(
            result.winner,
            equals('remote'),
            reason:
                'Expected winner=remote when remoteUpdatedAt ($remoteUpdatedAt) '
                '> localUpdatedAt ($localUpdatedAt), but got ${result.winner}.',
          );
          expect(
            result.winningPayload,
            equals(remotePayload),
            reason:
                'Expected winningPayload to be the remote payload when remote '
                'timestamp is later.',
          );
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Property 20c: For any conflict, exactly one row is logged to the
    // SyncConflicts table.
    //
    // Strategy:
    //   1. Generate two distinct minute offsets.
    //   2. Resolve a conflict.
    //   3. Assert the SyncConflicts table has exactly 1 row.
    //   4. Assert the row contains the correct entityType, entityId,
    //      localPayloadJson, remotePayloadJson, and winner.
    // -------------------------------------------------------------------------
    Glados(_genDistinctOffsets, _exploreConfig).test(
      'every conflict resolution logs exactly one row to SyncConflicts',
      (pair) async {
        final db = _openTestDb();
        try {
          final resolver = ConflictResolver(db);

          // pair[0] = earlier offset, pair[1] = later offset.
          final localUpdatedAt = _offsetToDateTime(pair[1]); // later → local wins
          final remoteUpdatedAt = _offsetToDateTime(pair[0]); // earlier

          const entityType = 'stock_adjustment';
          const entityId = 'adj-p20c';
          const localPayload = '{"id":"adj-p20c","local":true}';
          const remotePayload = '{"id":"adj-p20c","local":false}';

          await resolver.resolve(
            entityType: entityType,
            entityId: entityId,
            localPayload: localPayload,
            remotePayload: remotePayload,
            localUpdatedAt: localUpdatedAt,
            remoteUpdatedAt: remoteUpdatedAt,
          );

          final rows = await db.select(db.syncConflicts).get();

          expect(
            rows,
            hasLength(1),
            reason:
                'Expected exactly 1 conflict log row but found ${rows.length}.',
          );

          final row = rows.first;
          expect(row.entityType, equals(entityType));
          expect(row.entityId, equals(entityId));
          expect(row.localPayloadJson, equals(localPayload));
          expect(row.remotePayloadJson, equals(remotePayload));
          // Winner is always 'local' here since localOffset > remoteOffset.
          expect(row.winner, equals('local'));
          expect(row.localUpdatedAt, equals(localUpdatedAt));
          expect(row.remoteUpdatedAt, equals(remoteUpdatedAt));
        } finally {
          await db.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Property 20d: The winning payload always matches the version with the
    // later timestamp, regardless of which side (local/remote) has it.
    //
    // Strategy:
    //   1. Generate two distinct minute offsets.
    //   2. Run two resolutions: one where local is later, one where remote is later.
    //   3. In both cases, assert winningPayload == payload of the later timestamp.
    // -------------------------------------------------------------------------
    Glados(_genDistinctOffsets, _exploreConfig).test(
      'winningPayload always matches the payload with the later timestamp',
      (pair) async {
        final db = _openTestDb();
        try {
          final resolver = ConflictResolver(db);

          // pair[0] = earlier offset, pair[1] = later offset.
          final laterTime = _offsetToDateTime(pair[1]);
          final earlierTime = _offsetToDateTime(pair[0]);

          const payloadA = '{"tag":"A"}';
          const payloadB = '{"tag":"B"}';

          // Case 1: local is later → local payload should win.
          final resultLocalLater = await resolver.resolve(
            entityType: 'product',
            entityId: 'prod-d1',
            localPayload: payloadA,
            remotePayload: payloadB,
            localUpdatedAt: laterTime,
            remoteUpdatedAt: earlierTime,
          );

          expect(
            resultLocalLater.winningPayload,
            equals(payloadA),
            reason:
                'When local timestamp is later, winningPayload should be '
                'the local payload (payloadA).',
          );

          // Case 2: remote is later → remote payload should win.
          final resultRemoteLater = await resolver.resolve(
            entityType: 'product',
            entityId: 'prod-d2',
            localPayload: payloadA,
            remotePayload: payloadB,
            localUpdatedAt: earlierTime,
            remoteUpdatedAt: laterTime,
          );

          expect(
            resultRemoteLater.winningPayload,
            equals(payloadB),
            reason:
                'When remote timestamp is later, winningPayload should be '
                'the remote payload (payloadB).',
          );
        } finally {
          await db.close();
        }
      },
    );
  });
}
