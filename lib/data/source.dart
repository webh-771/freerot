// Contract every content source implements. Sources must be reachable with
// plain HTTP (no Cloudflare challenge solving).
import '../models.dart';

abstract class DramaSource {
  /// Stable key, e.g. "shortmax", "dramawave", "reelfren".
  String get key;

  /// True if this source serves dramas whose [Drama.source] is [dramaSource].
  /// Simple sources: `dramaSource == key`. ReelFren: `startsWith('rf:')`.
  bool handles(String dramaSource);

  /// Human label for a drama's source, e.g. "ShortMax", "NetShort".
  String label(String dramaSource);

  /// Relative weight in the mixed home feed (1 = normal).
  int get feedWeight => 1;

  /// Discovery feed, page >= 1. Mixed into Home by the Catalog.
  Future<Paged<Drama>> feed(int page);

  /// First-round search results (unranked; Catalog ranks + dedupes).
  /// Should return within ~15s; throw on failure.
  Future<List<Drama>> search(String query);

  Future<DramaDetail> detail(Drama drama);

  /// Server options to try in order, e.g. ["server1", "server2"].
  List<String> servers(DramaDetail detail);

  /// Resolve playback for [ep]. Throw [EpisodeLockedException] when the
  /// episode is known-unavailable; any other exception = try next server.
  Future<EpisodeStream> episode(DramaDetail detail, int ep,
      {required String server});
}

class SourceException implements Exception {
  final String message;
  SourceException(this.message);
  @override
  String toString() => message;
}

class EpisodeLockedException extends SourceException {
  EpisodeLockedException(super.message);
}
