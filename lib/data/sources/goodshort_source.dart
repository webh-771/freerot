// GoodShort mirror via its Cloudflare-free twin host
// cdn-goodshort.dramafren.org: plain HTTP, no WebView.
// Spec: probes/goodshort.md, probes/template_dramafren_unlocked.md.
//
// Quirks:
// - Site episode numbers are 0-based (`ep=0` = "001"); the app is 1-based, so
//   app ep N maps to site ep N-1.
// - Playback is two-step: the watch page with `ep=-1` (fast, no server-side
//   resolve) carries `var chapterIds = [...]` (index = site ep; cached per
//   drama), then `action=get_video_url&id&chap_id&sv&lang` returns an HLS
//   playlist proxied through cdn-goodshort (`/proxy?token=v2...`, plain TS).
// - The backend is slow/flaky when cold: 15 s per request, one retry.
import 'dart:async';
import 'dart:convert';

import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../../models.dart';
import '../source.dart';
import 'php_template.dart';
import 'shelf_hooks.dart';

class GoodShortSource extends DramaSource implements HistoryFeed {
  GoodShortSource({http.Client? client}) : _client = client ?? http.Client();

  static const String base = 'https://cdn-goodshort.dramafren.org/index.php';
  static const String lang = 'en';
  static const Duration timeout = Duration(seconds: 15);
  static const String userAgent =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36';

  final http.Client _client;
  final Map<String, DramaDetail> _details = {};
  final Map<String, List<String>> _chapters = {};

  @override
  String get key => 'goodshort';

  @override
  bool handles(String dramaSource) => dramaSource == key;

  @override
  String label(String dramaSource) => 'GoodShort';

  static String url(Map<String, String> params) =>
      Uri.parse(base).replace(queryParameters: params).toString();

  /// GET with a 15 s timeout and one retry on network errors / timeouts /
  /// 5xx (the backend is flaky when cold).
  Future<String> _get(String url, {bool json = false}) async {
    Object? last;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final res = await _client.get(Uri.parse(url), headers: {
          'User-Agent': userAgent,
          'Accept': json ? 'application/json' : 'text/html,*/*',
        }).timeout(timeout);
        // JSON error bodies (4xx) still carry the status/message.
        if (res.statusCode == 200 ||
            (json && res.statusCode >= 400 && res.statusCode < 500 &&
                res.body.trimLeft().startsWith('{'))) {
          return utf8.decode(res.bodyBytes, allowMalformed: true);
        }
        last = SourceException('GoodShort: HTTP ${res.statusCode}');
        if (res.statusCode < 500) break;
      } on TimeoutException {
        last = SourceException('GoodShort: request timed out');
      } catch (e) {
        last = SourceException('GoodShort: network error ($e)');
      }
    }
    throw last ?? SourceException('GoodShort: request failed');
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
    final html = await _get(url({'page': 'home', 'p_hist': '$page'}));
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
    final html = await _get(
      url({'page': 'detail', 'id': drama.id, 'lang': lang, 'sv': '1'}),
    );
    final d = parseGoodShortDetail(html, id: drama.id, fallback: drama);
    _details[drama.id] = d;
    return d;
  }

  @override
  List<String> servers(DramaDetail detail) => const ['server1', 'server2'];

  /// chapterIds for [id] (index = 0-based site ep), cached per drama.
  Future<List<String>> chapterIds(String id) async {
    final hit = _chapters[id];
    if (hit != null) return hit;
    final html = await _get(
      url({'page': 'watch', 'id': id, 'ep': '-1', 'lang': lang, 'sv': '1'}),
    );
    final ids = parseGoodShortChapterIds(html);
    if (ids.isEmpty) {
      throw SourceException('GoodShort: no chapter list for drama $id');
    }
    _chapters[id] = ids;
    return ids;
  }

  @override
  Future<EpisodeStream> episode(DramaDetail detail, int ep,
      {required String server}) async {
    final sv = int.tryParse(server.replaceAll(RegExp(r'\D'), '')) ?? 1;
    final chaps = await chapterIds(detail.id);
    final idx = ep - 1; // app is 1-based, site is 0-based
    if (idx < 0 || idx >= chaps.length) {
      throw EpisodeLockedException(
          'GoodShort: episode $ep not available (${chaps.length} chapters)');
    }
    final body = await _get(
      url({
        'action': 'get_video_url',
        'id': detail.id,
        'chap_id': chaps[idx],
        'sv': '$sv',
        'lang': lang,
      }),
      json: true,
    );
    final all = servers(detail);
    return parseGoodShortVideo(
      body,
      dramaId: detail.id,
      ep: ep,
      server: server,
      lastServer: all.isEmpty || all.last == server,
    );
  }
}

/// Detail page -> [DramaDetail] with 1-based app episode numbers
/// (site `ep=0..N-1` -> app `1..N`).
DramaDetail parseGoodShortDetail(String html,
    {required String id, Drama? fallback}) {
  final TemplateDetail t;
  try {
    t = parseTemplateDetail(html);
  } on FormatException {
    throw SourceException('GoodShort: drama $id not found');
  }
  final doc = html_parser.parse(html);
  final eps = <int>{};
  for (final a in doc.querySelectorAll('a[href*="page=watch"]')) {
    final siteEp = int.tryParse(hrefParams(a.attributes['href'])['ep'] ?? '');
    if (siteEp != null && siteEp >= 0) eps.add(siteEp + 1);
  }
  var episodes = eps.toList()..sort();
  var total = t.total;
  if (episodes.isNotEmpty && episodes.last > total) total = episodes.last;
  if (episodes.isEmpty && total > 0) {
    episodes = List<int>.generate(total, (i) => i + 1);
  }
  return DramaDetail(
    source: 'goodshort',
    id: id,
    title: t.title.isNotEmpty ? t.title : (fallback?.title ?? ''),
    cover: t.cover.isNotEmpty ? t.cover : (fallback?.cover ?? ''),
    synopsis: t.synopsis,
    totalEpisodes: total,
    episodes: episodes,
  );
}

/// `var chapterIds = ['66155558', ...]` from a watch page ([] if missing).
List<String> parseGoodShortChapterIds(String html) {
  final m = RegExp(r'chapterIds\s*=\s*\[(.*?)\]', dotAll: true).firstMatch(html);
  if (m == null) return const [];
  return RegExp(r'''["']?(\d+)["']?''')
      .allMatches(m.group(1)!)
      .map((x) => x.group(1)!)
      .toList();
}

/// `action=get_video_url` JSON -> [EpisodeStream]. A non-success status is a
/// [SourceException] (try the next server), or [EpisodeLockedException] when
/// [lastServer] is true.
EpisodeStream parseGoodShortVideo(String body,
    {required String dramaId,
    required int ep,
    required String server,
    bool lastServer = false}) {
  Object? j;
  try {
    j = jsonDecode(body);
  } catch (_) {
    j = null;
  }
  if (j is! Map) throw SourceException('GoodShort: bad get_video_url response');
  final play = '${j['video_url'] ?? ''}'.trim();
  if (j['status'] != 'success' || !play.startsWith('http')) {
    final why = j['message'] ?? j['error'] ?? j['status'] ?? 'no stream';
    final msg = 'GoodShort: episode $ep unavailable on $server ($why)';
    throw lastServer ? EpisodeLockedException(msg) : SourceException(msg);
  }
  final qs = <VideoQuality>[];
  final raw = j['qualities'];
  if (raw is List) {
    for (final q in raw) {
      if (q is! Map || q['url'] is! String) continue;
      final u = (q['url'] as String).trim();
      if (!u.startsWith('http')) continue;
      final label = cleanText('${q['quality'] ?? q['label'] ?? 'Auto'}')
          .replaceAllMapped(RegExp(r'^(\d+)P$'), (m) => '${m[1]}p');
      qs.add(VideoQuality(label, u, isHls: true));
    }
  }
  int rank(String l) => int.tryParse(RegExp(r'\d+').stringMatch(l) ?? '') ?? 0;
  qs.sort((a, b) => rank(b.label).compareTo(rank(a.label)));
  return EpisodeStream(
    dramaId: dramaId,
    ep: ep,
    server: server,
    playUrl: play,
    proxyUrl: '',
    isHls: true,
    qualities: qs,
  );
}
