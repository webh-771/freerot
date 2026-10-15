// OWNER: web-session agent. DramaBite mirror (dramabite.dramafren.org,
// MiniEpisode backend). Cloudflare-protected: pages go through WebSession.
// Spec: probes/dramabite.md. Watch pages inline `videoSrc = atob("...")`.
import '../../models.dart';
import '../web/template_web_source.dart';
import 'shelf_hooks.dart';

class DramaBiteSource extends TemplateWebSource
    implements HistoryFeed, SessionGated {
  DramaBiteSource({super.fetch});

  static const String lang = 'en';

  /// Its home feed *is* the live "Recently Watched" list.
  @override
  Future<Paged<Drama>> recentlyWatched(int page) => feed(page);

  @override
  String get key => 'dramabite';

  @override
  String get displayName => 'DramaBite';

  @override
  String get origin => 'https://dramabite.dramafren.org';

  @override
  String get feedPageParam => 'p_hist';

  @override
  String feedUrl(int page) => url({'page': 'home', 'p_hist': '$page'});

  @override
  String searchUrl(String query) =>
      url({'page': 'search_result', 'q': query, 'lang': lang});

  @override
  String detailUrl(String siteId, String? slug) =>
      url({'page': 'detail', 'id': siteId, 'lang': lang});

  @override
  String watchUrl(String siteId, String? slug, int ep, int server) => url({
        'page': 'watch',
        'id': siteId,
        'ep': '$ep',
        'lang': lang,
        'server': '$server',
      });
}
