// OWNER: catalog agent. Optional capability for sources that can deliver
// search results in chunks (e.g. ReelFren fans out per provider). The
// Catalog listens to the chunks and re-emits the ranked list as they land.
import '../../models.dart';

abstract interface class ProgressiveSearch {
  /// Emits each batch of (unranked) results as it arrives; completes when
  /// the source is done. Errors of individual batches are swallowed.
  Stream<List<Drama>> searchChunks(String query);
}
