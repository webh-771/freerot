// FlickReels mirror via its Cloudflare-free twin host
// cdn-flickreels.dramafren.org: plain HTTP, no WebView.
// Spec: probes/flickreels.md, probes/template_dramafren_unlocked.md.
//
// Quirks:
// - The m3u8 is baked into the watch page (`var initialVideoUrl = "..."`, a
//   JSON string). Plain HLS with relative MPEG-TS segments, no headers.
// - Only server 1 works (server2_stream / server3_stream / proxy_m3u8 all
//   failed in probing), so there is a single server option.
// - The `verify=` token expires ~45-60 min after issue: stream URLs are never
//   cached; every episode() call re-fetches the watch page.
import 'dart:async';
import 'dart:convert';

import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../../models.dart';
import '../source.dart';
import 'php_template.dart';
import 'shelf_hooks.dart';

class FlickReelsSource extends DramaSource implements HistoryFeed {
  FlickReelsSource({http.Client? client}) : _client = client ?? http.Client();

  static const String base = 'https://cdn-flickreels.dramafren.org/index.php';
  static const String lang = 'en';
  static const Duration timeout = Duration(seconds: 15);
  static const String userAgent =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36';

  final http.Client _client;
  final Map<String, DramaDetail> _details = {};

  @override
  String get key => 'flickreels';

  @override
  bool handles(String dramaSource) => dramaSource == key;

  @override
  String label(String dramaSource) => 'FlickReels';

  static String url(Map<String, String> params) =>
      Uri.parse(base).replace(queryParameters: params).toString();

  Future<String> _get(String url) async {
    final http.Response res;
    try {
      res = await _client.get(Uri.parse(url), headers: {
        'User-Agent': userAgent,
        'Accept': 'text/html,*/*',
      }).timeout(timeout);
    } on TimeoutException {
      throw SourceException('FlickReels: request timed out');
    } catch (e) {
      throw SourceException('FlickReels: network error ($e)');
    }
    if (res.statusCode != 200) {
      throw SourceException('FlickReels: HTTP ${res.statusCode}');
    }
    return utf8.decode(res.bodyBytes, allowMalformed: true);
  }

  Drama _toDrama(TemplateCard c) => Drama(
        source: key,
        id: c.id,
        title: c.title,
        cover: c.cover,
        episodes: c.episodes,
      );

  @override
  Future<Paged<Drama>> feed(int page) async {
    final html =
        await _get(url({'page': 'home', 'p_hist': '$page', 'lang': lang}));
    final block = sliceFrom(html, 'Recently Watched');
    return Paged(
      parseTemplateCards(block).map(_toDrama).toList(),
      templateHasNext(block, 'p_hist', page),
    );
  }

  /// Its home feed *is* the live "Recently Watched" list.
  @override
  Future<Paged<Drama>> recentlyWatched(int page) => feed(page);

  @override
  Future<List<Drama>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final html =
        await _get(url({'page': 'search_result', 'q': q, 'lang': lang}));
    return parseTemplateCards(html).map(_toDrama).toList();
  }

  @override
  Future<DramaDetail> detail(Drama drama) async {
    final hit = _details[drama.id];
    if (hit != null) return hit;
    final html =
        await _get(url({'page': 'detail', 'id': drama.id, 'lang': lang}));
    final TemplateDetail t;
    try {
      t = parseTemplateDetail(html);
    } on FormatException {
      throw SourceException('FlickReels: drama ${drama.id} not found');
    }
    final d = DramaDetail(
      source: key,
      id: drama.id,
      title: t.title.isNotEmpty ? t.title : drama.title,
      cover: t.cover.isNotEmpty ? t.cover : drama.cover,
      synopsis: t.synopsis,
      totalEpisodes: t.total,
      episodes: t.episodes,
    );
    _details[drama.id] = d;
    return d;
  }

  @override
  List<String> servers(DramaDetail detail) => const ['server1'];

  @override
  Future<EpisodeStream> episode(DramaDetail detail, int ep,
      {required String server}) async {
    // Never cached: the verify= token expires in ~45-60 min.
    final html = await _get(
      url({'page': 'watch', 'id': detail.id, 'ep': '$ep', 'lang': lang}),
    );
    final m3u8 = flickReelsVideoUrlOf(html);
    if (m3u8 == null) {
      throw EpisodeLockedException(
          'FlickReels: no stream for episode $ep of ${detail.id}');
    }
    return EpisodeStream(
      dramaId: detail.id,
      ep: ep,
      server: server,
      playUrl: m3u8,
      proxyUrl: '',
      isHls: true,
      qualities: const [],
    );
  }
}

/// The episode m3u8 from a watch page: `var initialVideoUrl = "..."` (JSON
/// string, `\/` escaped), else `video#player[src]`. null if neither has an
/// http(s) URL.
String? flickReelsVideoUrlOf(String html) {
  final m = RegExp(r'''initialVideoUrl\s*=\s*"((?:[^"\\]|\\.)*)"''')
      .firstMatch(html);
  if (m != null) {
    String? u;
    try {
      u = jsonDecode('"${m.group(1)!}"') as String;
    } catch (_) {
      u = m.group(1)!.replaceAll(r'\/', '/');
    }
    u = u.trim();
    if (u.startsWith('http')) return u;
  }
  final src = html_parser
      .parse(html)
      .querySelector('video#player')
      ?.attributes['src']
      ?.trim();
  if (src != null && src.startsWith('http')) return src;
  return null;
}
