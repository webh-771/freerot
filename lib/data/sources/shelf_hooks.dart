// OWNER: shelves agent. Optional capabilities sources can implement so the
// Catalog can build the Home shelves (lib/data/shelves.dart). All optional:
// a source that implements none of them only shows up in "For you" and in
// the genre shelves (through its search).
import '../../models.dart';

/// The mirror's live "Recently watched" list (what other viewers are
/// watching right now). Used by the 'trending' shelf.
abstract interface class HistoryFeed {
  Future<Paged<Drama>> recentlyWatched(int page);
}

/// Newest-first listings. A source can expose several independent lanes
/// (e.g. one per ReelFren provider); each is paged from 1.
abstract interface class NewestFeed {
  List<String> get newestLanes;
  Future<Paged<Drama>> newest(String lane, int page);
}

/// Real view counts ([Drama.views]). Used by the 'most_viewed' shelf.
abstract interface class ViewCounts {
  /// A quick partial list with views (a few seconds), may be empty.
  Future<List<Drama>> viewedQuick();

  /// The full catalogue with views (slow; cached by the source).
  Future<List<Drama>> viewedAll();

  /// The full catalogue if it is already loaded, else null. Never fetches.
  List<Drama>? get viewedCached;
}

/// Official categories (ShortMax "Werewolf", "Mafia Romance", ...).
abstract interface class CategoryListing {
  /// Items of every category whose display name satisfies [match].
  Future<List<Drama>> categoryItems(bool Function(String name) match);
}

/// Marker: the source is fetched through a WebView session (Cloudflare).
/// Shelves only use it once it has already served something this session,
/// so building a shelf never starts a challenge.
abstract interface class SessionGated {}
