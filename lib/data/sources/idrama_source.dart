// OWNER: web-session agent. iDrama mirror via its Cloudflare-free twin host
// cdn-idrama.dramafren.org: plain HTTP, no WebView. Spec: probes/idrama.md
//
// Playback comes from the `action=watch_stream` JSON; the stream is standard
// HLS AES-128 (key URL is public), which ExoPlayer decrypts natively.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models.dart';
import '../source.dart';
import 'php_template.dart';
import 'shelf_hooks.dart';

class IDramaSource extends DramaSource implements HistoryFeed {
  IDramaSource({http.Client? client}) : _client = client ?? http.Client();

  static const String base = 'https://cdn-idrama.dramafren.org/index.php';
  static const String lang = 'en';
  static const Duration timeout = Duration(seconds: 15);
  static const String userAgent =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36';

  final http.Client _client;
  final Map<String, DramaDetail> _details = {};

  @override
  String get key => 'idrama';

  @override
  bool handles(String dramaSource) => dramaSource == key;

  @override
  String label(String dramaSource) => 'iDrama';

  static String url(Map<String, String> params) =>
      Uri.parse(base).replace(queryParameters: params).toString();

  Future<String> _get(String url, {bool json = false}) async {
    final res = await _client.get(Uri.parse(url), headers: {
      'User-Agent': userAgent,
      'Accept': json ? 'application/json' : 'text/html,*/*',
    }).timeout(timeout);
    if (res.statusCode != 200) {
      throw SourceException('iDrama: HTTP ${res.statusCode}');
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
    final html = await _get(
      url({'page': 'home', 'p_hist': '$page', 'lang': lang}),
    );
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
    final html = await _get(url({'page': 'search', 'q': q, 'lang': lang}));
    return parseTemplateCards(html).map(_toDrama).toList();
  }

  @override
  Future<DramaDetail> detail(Drama drama) async {
    final hit = _details[drama.id];
    if (hit != null) return hit;
    final t = parseTemplateDetail(
      await _get(url({'page': 'detail', 'id': drama.id, 'lang': lang})),
    );
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
  List<String> servers(DramaDetail detail) =>
      const ['server1', 'server2', 'server3'];

  @override
  Future<EpisodeStream> episode(DramaDetail detail, int ep,
      {required String server}) async {
    final no = int.tryParse(server.replaceAll(RegExp(r'\D'), '')) ?? 1;
    final body = await _get(
      url({
        'action': 'watch_stream',
        'id': detail.id,
        'ep': '$ep',
        'server': '$no',
        'lang': lang,
        '_': '${DateTime.now().millisecondsSinceEpoch}',
      }),
      json: true,
    );
    return parseIDramaStream(body, dramaId: detail.id, ep: ep, server: server);
  }
}

/// Parses `action=watch_stream` JSON into an [EpisodeStream].
/// `video_url` is the mirror's proxy; its `url=` param is the direct signed
/// m3u8 (played first, proxy kept as the alternate).
EpisodeStream parseIDramaStream(String body,
    {required String dramaId, required int ep, required String server}) {
  final Object? j;
  try {
    j = jsonDecode(body);
  } catch (_) {
    throw SourceException('iDrama: bad watch_stream response');
  }
  if (j is! Map) throw SourceException('iDrama: bad watch_stream response');
  final proxied = (j['video_url'] as String?)?.trim() ?? '';
  if (j['ok'] != true || proxied.isEmpty) {
    throw SourceException('iDrama: ${j['error'] ?? 'no video for ep $ep'}');
  }
  final direct = Uri.tryParse(proxied)?.queryParameters['url'] ?? '';
  final play = direct.startsWith('http') ? direct : proxied;

  final subs = <Subtitle>[];
  final raw = j['subs'];
  if (raw is List) {
    for (final s in raw) {
      if (s is! Map || s['url'] is! String) continue;
      final code = '${s['code'] ?? s['language'] ?? s['lang'] ?? ''}';
      final name = '${s['label'] ?? s['language'] ?? s['name'] ?? code}';
      subs.add(Subtitle(
        name.isEmpty ? 'Subtitles' : name,
        code,
        IDramaSource.url({'action': 'proxy_sub', 'url': s['url'] as String}),
      ));
    }
  }
  return EpisodeStream(
    dramaId: dramaId,
    ep: ep,
    server: server,
    playUrl: play,
    proxyUrl: play == proxied ? '' : proxied,
    isHls: true,
    qualities: const [],
    subtitles: subs,
  );
}
