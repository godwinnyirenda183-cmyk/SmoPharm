import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pharmacy_pos/data/services/conflict_resolver.dart';
import 'package:pharmacy_pos/data/services/offline_queue_service.dart';
import 'package:pharmacy_pos/data/services/supabase_uploader.dart';
import 'package:pharmacy_pos/data/services/sync_service_impl.dart';
import 'package:pharmacy_pos/domain/services/sync_service.dart';
import 'package:pharmacy_pos/providers/database_provider.dart';

/// Provides the [SyncService] instance backed by [SyncServiceImpl].
///
/// Uses [supabaseEntryUploader] to upload queued entries to Supabase when
/// connectivity is available.
final syncServiceProvider = Provider<SyncService>((ref) {
  final db = ref.watch(databaseProvider);
  final queueService = OfflineQueueService(db);
  final conflictResolver = ConflictResolver(db);

  final service = SyncServiceImpl(
    queueService: queueService,
    uploader: supabaseEntryUploader,
    conflictResolver: conflictResolver,
  );

  ref.onDispose(service.dispose);
  return service;
});

/// A [StreamProvider] that exposes the current [SyncStatus] from [SyncService].
/// Defaults to [SyncStatus.offline] while the stream has not emitted yet.
final syncStatusProvider = StreamProvider<SyncStatus>((ref) {
  final syncService = ref.watch(syncServiceProvider);
  return syncService.statusStream;
});
