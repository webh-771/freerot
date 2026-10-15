// OWNER: catalog agent. ShortMax (shorttv) wrapped as a DramaSource.
// Official catalogue for the feed, dramafren site for search/detail/video.
import 'dart:async';

import '../../models.dart';
import '../api.dart';
import '../source.dart';
import 'shelf_hooks.dart';

class ShortMaxSource extends DramaSource
    implements HistoryFeed, NewestFeed, ViewCounts, CategoryListing {
  ShortMaxSource({ShortMaxApi? api}) : _api = api ?? ShortMaxApi.instance;

  final ShortMaxApi _api;

  @override
  String get key => kShortMaxSource;

  @override
  bool handles(String dramaSource) => dramaSource == kShortMaxSource;

  @override
  String label(String dramaSource) => 'ShortMax';

  /// Official browse — slow (~12 s unfiltered), cached 10 min by the api.
  @override
  Future<Paged<Drama>> feed(int page) =>
      _wrap(() => _api.browse(page: page < 1 ? 1 : page));

  /// Site search page 1, plus page 2 when it is quick to get.
  @override
  Future<List<Drama>> search(String query) => _wrap(() async {
        final sw = Stopwatch()..start();
        final p1 = await _api.search(query);
        final out = [...p1.items];
        if (p1.hasMore && sw.elapsed < const Duration(seconds: 6)) {
          try {
            final p2 = await _api
                .search(query, page: 2)
                .timeout(const Duration(seconds: 6));
            final ids = out.map((d) => d.id).toSet();
            out.addAll(p2.items.where((d) => ids.add(d.id)));
          } catch (_) {
            // page 2 is a bonus
          }
        }
        return out.map(_api.withViews).toList();
      });

  @override
  Future<DramaDetail> detail(Drama drama) => _wrap(() => _api.detail(drama.id));

  @override
  List<String> servers(DramaDetail detail) => const ['server1', 'server2'];

  @override
  Future<EpisodeStream> episode(
    DramaDetail detail,
    int ep, {
    required String server,
  }) =>
      _wrap(() => _api.episode(detail.id, ep, server: server));

  // ----------------------------------------------------------- shelf hooks

  /// The mirror's live "Recently Watched" list.
  @override
  Future<Paged<Drama>> recentlyWatched(int page) => _wrap(() async {
        final p = await _api.siteRecent(page: page < 1 ? 1 : page);
        return Paged(p.items.map(_api.withViews).toList(), p.hasMore);
      });

  /// Official default order is newest first (shortPlayCode descending).
  @override
  List<String> get newestLanes => const ['official'];

  static const int _newestPageSize = 24;

  /// Slices of the loaded catalogue (same order) when available, else the
  /// feed's pages (shared cache with "For you").
  @override
  Future<Paged<Drama>> newest(String lane, int page) async {
    final all = _api.cachedCatalogue();
    if (all == null) return feed(page);
    final from = ((page < 1 ? 1 : page) - 1) * _newestPageSize;
    if (from >= all.length) return const Paged([], false);
    final to = (from + _newestPageSize).clamp(0, all.length);
    return Paged(all.sublist(from, to), to < all.length);
  }

  /// Official category ids the most-viewed shelf reads first while the
  /// whole catalogue loads: small ones that answer in ~3-4 s ("hot",
  /// "Billionaire Lifestyle", "Sci-Fi", "Legendary Warrior"; ids from
  /// cmsClassNew/queryList, stable since first seen).
  static const List<int> quickClassIds = [200008, 200015, 200009, 200018];

  @override
  Future<List<Drama>> viewedQuick() async {
    final pages = await Future.wait([
      for (final id in quickClassIds)
        _api
            .browse(classId: id, pageSize: ShortMaxApi.maxPageSize)
            .then((p) => p.items, onError: (_) => const <Drama>[]),
    ]);
    final seen = <String>{};
    return [
      for (final d in [..._api.cachedOfficial(), ...pages.expand((l) => l)])
        if (d.views != null && seen.add(d.id)) d,
    ];
  }

  @override
  Future<List<Drama>> viewedAll() => _wrap(_api.catalogue);

  @override
  List<Drama>? get viewedCached => _api.cachedCatalogue();

  /// First 100 items of every matching official category, in parallel
  /// (failed categories are skipped).
  @override
  Future<List<Drama>> categoryItems(bool Function(String name) match) =>
      _wrap(() async {
        final classes = (await _api.categories()).where((c) => match(c.name));
        final pages = await Future.wait([
          for (final c in classes)
            _api
                .browse(classId: c.classId, pageSize: ShortMaxApi.maxPageSize)
                .then((p) => p.items, onError: (_) => const <Drama>[]),
        ]);
        final seen = <String>{};
        return [
          for (final list in pages)
            for (final d in list)
              if (seen.add(d.id)) d,
        ];
      });

  Future<T> _wrap<T>(Future<T> Function() f) async {
    try {
      return await f();
    } on ShortMaxException catch (e) {
      throw SourceException(e.message);
    }
  }
}
