// OWNER: web-session agent. Shared DramaSource for the Cloudflare-protected
// dramafren PHP mirrors (stardusttv, starshort, dramabite). Pages are fetched
// through [WebSession.get]; stream URLs are CF-free and played directly.
import 'dart:async';

import '../../models.dart';
import '../source.dart';
import '../sources/php_template.dart';
import 'web_session.dart';

/// Fetches a page body. Defaults to [WebSession.get]; tests pass fixtures.
typedef PageFetcher = Future<String> Function(String url);

abstract class TemplateWebSource extends DramaSource {
  TemplateWebSource({PageFetcher? fetch})
      : _fetch = fetch ?? ((url) => WebSession.instance.get(url));

  final PageFetcher _fetch;
  final Map<String, DramaDetail> _details = {};

  /// Covers seen in feeds / details, by site id. Search pages on some mirrors
  /// only carry placeholders.
  final Map<String, String> _covers = {};

  /// `https://<site>.dramafren.org`.
  String get origin;
  String get displayName;

  /// Query param the feed pager uses (`hp` or `p_hist`).
  String get feedPageParam;

  String get base => '$origin/index.php';

  String url(Map<String, String> params) =>
      Uri.parse(base).replace(queryParameters: params).toString();

  String feedUrl(int page);
  String searchUrl(String query);

  /// [siteId] is the id as the site knows it, [slug] only for stardusttv.
  String detailUrl(String siteId, String? slug);
  String watchUrl(String siteId, String? slug, int ep, int server);

  /// [Drama.id] for a card. Default: the site id.
  String dramaIdOf(TemplateCard c) => c.id;

  /// `(siteId, slug)` back from a [Drama.id].
  (String, String?) splitId(String dramaId) => (dramaId, null);

  /// Hook: reject a resolved stream URL (throw [SourceException]).
  void checkStream(String url) {}

  Future<String> fetchPage(String url) => _fetch(url);

  @override
  String get key;

  @override
  bool handles(String dramaSource) => dramaSource == key;

  @override
  String label(String dramaSource) => displayName;

  Drama _toDrama(TemplateCard c) {
    if (c.cover.isNotEmpty) _covers[c.id] = c.cover;
    return Drama(
      source: key,
      id: dramaIdOf(c),
      title: c.title,
      cover: c.cover.isNotEmpty ? c.cover : (_covers[c.id] ?? ''),
      episodes: c.episodes,
    );
  }

  @override
  Future<Paged<Drama>> feed(int page) async {
    final html = await fetchPage(feedUrl(page));
    final cards = parseTemplateCards(html, after: 'Recently Watched');
    return Paged(
      cards.map(_toDrama).toList(),
      templateHasNext(sliceFrom(html, 'Recently Watched'), feedPageParam, page),
    );
  }

  @override
  Future<List<Drama>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final html = await fetchPage(searchUrl(q));
    return parseTemplateCards(html).map(_toDrama).toList();
  }

  @override
  Future<DramaDetail> detail(Drama drama) async {
    final hit = _details[drama.id];
    if (hit != null) return hit;
    final (siteId, slug) = splitId(drama.id);
    final t = parseTemplateDetail(await fetchPage(detailUrl(siteId, slug)));
    final cover = t.cover.isNotEmpty ? t.cover : drama.cover;
    if (cover.isNotEmpty) _covers[siteId] = cover;
    final d = DramaDetail(
      source: key,
      id: drama.id,
      title: t.title.isNotEmpty ? t.title : drama.title,
      cover: cover,
      synopsis: t.synopsis,
      totalEpisodes: t.total,
      episodes: t.episodes,
    );
    _details[drama.id] = d;
    return d;
  }

  @override
  List<String> servers(DramaDetail detail) => const ['server1', 'server2'];

  static int serverNo(String server) =>
      int.tryParse(server.replaceAll(RegExp(r'\D'), '')) ?? 1;

  @override
  Future<EpisodeStream> episode(DramaDetail detail, int ep,
      {required String server}) async {
    final (siteId, slug) = splitId(detail.id);
    final html = await fetchPage(watchUrl(siteId, slug, ep, serverNo(server)));
    final src = watchVideoUrlOf(html);
    if (src == null || src.isEmpty) {
      throw SourceException('$displayName: no video for ep $ep on $server');
    }
    checkStream(src);
    final quals = availableQualitiesOf(html);
    return EpisodeStream(
      dramaId: detail.id,
      ep: ep,
      server: server,
      playUrl: src,
      proxyUrl: '',
      isHls: !src.contains('.mp4'),
      qualities: quals.length > 1 ? quals : const [],
    );
  }
}
