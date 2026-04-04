import '../entities/batch.dart';

/// Abstract repository for batch management and FEFO selection.
abstract class BatchRepository {
  /// Creates a new batch and returns the persisted entity.
  /// [nearExpiryWindowDays] is used to compute the initial batch status.
  Future<Batch> create(BatchInput input, {required int nearExpiryWindowDays});

  /// Selects the batch for [productId] with the earliest expiry date that has
  /// at least [quantityNeeded] remaining (FEFO). Returns null if no such batch
  /// exists.
  Future<Batch?> selectFEFO(String productId, int quantityNeeded);

  /// Returns all non-expired batches whose expiry date falls within
  /// [windowDays] days from today.
  Future<List<Batch>> nearExpiry(int windowDays);

  /// Returns all batches whose expiry date has passed.
  Future<List<Batch>> expiredBatches();
}
