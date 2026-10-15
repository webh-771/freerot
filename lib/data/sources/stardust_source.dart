// OWNER: web-session agent. StardustTV mirror (stardusttv.dramafren.org).
// Cloudflare-protected: pages go through WebSession. Spec: probes/stardusttv.md
//
// Drama.id is "<siteId>/<slug>": detail and watch URLs need the slug.
import '../../models.dart';
import '../web/template_web_source.dart';
import 'shelf_hooks.dart';
import 'php_template.dart';

class StardustSource extends TemplateWebSource
    implements HistoryFeed, SessionGated {
  StardustSource({super.fetch});

  static const String lang = 'en_US';

  /// Its home feed *is* the live "Recently Watched" list.
  @override
  Future<Paged<Drama>> recentlyWatched(int page) => feed(page);

  @override
  String get key => 'stardust';

  @override
  String get displayName => 'StardustTV';

  @override
  String get origin => 'https://stardusttv.dramafren.org';

  @override
  String get feedPageParam => 'hp';

  @override
  String feedUrl(int page) => url({'hp': '$page'});

  @override
  String searchUrl(String query) =>
      url({'page': 'search_result', 'q': query, 'lang': lang});

  @override
  String detailUrl(String siteId, String? slug) => url({
        'page': 'detail',
        'id': siteId,
        'slug': ?slug,
        'lang': lang,
      });

  @override
  String watchUrl(String siteId, String? slug, int ep, int server) => url({
        'page': 'watch',
        'id': siteId,
        'slug': ?slug,
        'ep': '$ep',
        'sv': '$server',
        'lang': lang,
      });

  @override
  String dramaIdOf(TemplateCard c) =>
      c.slug == null ? c.id : '${c.id}/${c.slug}';

  @override
  (String, String?) splitId(String dramaId) {
    final i = dramaId.indexOf('/');
    return i < 0
        ? (dramaId, null)
        : (dramaId.substring(0, i), dramaId.substring(i + 1));
  }
}
