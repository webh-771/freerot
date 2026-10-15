// OWNER: web-session agent. StarShort mirror (starshort.dramafren.org).
// Cloudflare-protected: pages go through WebSession. Spec: probes/starshort.md
//
// Gotchas handled here:
//  * the mirror caches signed stream URLs server-side and keeps serving them
//    after `auth_key` expires (CDN then answers 403) -> SourceException, so
//    the player moves on to the other server;
//  * search results only carry placeholder covers -> filled from the cover
//    cache or a few detail pages within a short budget.
import 'dart:async';

import '../../models.dart';
import '../source.dart';
import '../web/template_web_source.dart';
import 'shelf_hooks.dart';
import 'php_template.dart';

class StarShortSource extends TemplateWebSource
    implements HistoryFeed, SessionGated {
  StarShortSource({super.fetch, DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  /// Numeric language id; 3 = English.
  static const String lang = '3';

  /// How long search may spend fetching real covers.
  static const Duration coverBudget = Duration(seconds: 5);
  static const int maxCoverLookups = 10;

  /// Its home feed *is* the live "Recently Watched" list.
  @override
  Future<Paged<Drama>> recentlyWatched(int page) => feed(page);

  @override
  String get key => 'starshort';

  @override
  String get displayName => 'StarShort';

  @override
  String get origin => 'https://starshort.dramafren.org';

  @override
  String get feedPageParam => 'p_hist';

  @override
  String feedUrl(int page) => url({'page': 'home', 'p_hist': '$page'});

  @override
  String searchUrl(String query) =>
      url({'page': 'search_result', 'q': query, 'lang': lang});

  @override
  String detailUrl(String siteId, String? slug) =>
      url({'page': 'detail', 'id': siteId});

  @override
  String watchUrl(String siteId, String? slug, int ep, int server) => url({
        'page': 'watch',
        'id': siteId,
        'ep': '$ep',
        'lang': lang,
        'server': '$server',
      });

  @override
  void checkStream(String url) {
    final exp = authKeyExpiry(url);
    if (exp == null) return;
    final nowS = _now().millisecondsSinceEpoch ~/ 1000;
    if (exp <= nowS + 30) {
      throw SourceException('StarShort: cached stream link expired');
    }
  }

  @override
  Future<List<Drama>> search(String query) async {
    final items = await super.search(query);
    final missing =
        items.where((d) => d.cover.isEmpty).take(maxCoverLookups).toList();
    if (missing.isEmpty) return items;
    final covers = <String, String>{};
    try {
      await Future.wait(missing.map((d) async {
        try {
          final det = await detail(d);
          if (det.cover.isNotEmpty) covers[d.id] = det.cover;
        } catch (_) {}
      })).timeout(coverBudget);
    } on TimeoutException {
      // Use whatever arrived in time.
    }
    return [
      for (final d in items)
        covers.containsKey(d.id)
            ? Drama(
                source: d.source,
                id: d.id,
                title: d.title,
                cover: covers[d.id]!,
                episodes: d.episodes,
                synopsis: d.synopsis,
              )
            : d,
    ];
  }
}
