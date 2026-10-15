// microdrama.dramafren.org — "ReelTV / MicroDrama" catalogue (see
// probes/microdrama.md).
//
// All JSON comes from `GET https://microdrama.dramafren.org/?api_route=<route>
// &lang=en&...`, which sits behind a Cloudflare managed challenge, so every API
// call goes through [WebSession.get] (same-origin fetch inside a WebView; the
// user completes the challenge in a popup). [NeedsVerificationException] is
// propagated unchanged so the UI can show the verify banner.
//
// Videos are direct progressive MP4s on reeltv.janzhoutec.com (CF-free, no
// headers, signed `auth_key` valid ~2 days). The detail response already
// carries every episode's URLs, so detail is cached and [episode] needs no
// extra request.
//
// Quirks:
// - `list` ignores paging (always the newest 50) → feed page 1 only.
// - `search` returns all matches at once; empty `q` is an upstream error.
// - Ids are per-language; this source always uses `lang=en`.
import 'dart:async';
import 'dart:convert';

import '../../models.dart';
import '../source.dart';
import '../web/web_session.dart';
import 'shelf_hooks.dart';

class MicroDramaSource extends DramaSource implements SessionGated {
  static const sourceKey = 'microdrama';
  static const host = 'microdrama.dramafren.org';
  static const origin = 'https://$host';
  static const lang = 'en';
  static const timeout = Duration(seconds: 20);

  /// Re-fetch detail after this long even if the auth_key looks valid.
  static const cacheTtl = Duration(hours: 12);

  final Future<String> Function(String url) _fetch;

  MicroDramaSource({Future<String> Function(String url)? fetch})
    : _fetch = fetch ?? ((url) => WebSession.instance.get(url));

  final Map<String, MicroDramaDetail> _cache = {};

  @override
  String get key => sourceKey;

  @override
  bool handles(String dramaSource) => dramaSource == sourceKey;

  @override
  String label(String dramaSource) => 'MicroDrama';

  static String apiUrl(String route, [Map<String, String> params = const {}]) =>
      Uri.https(host, '/', {
        'api_route': route,
        'lang': lang,
        ...params,
      }).toString();

  Future<Map<String, dynamic>> _api(
    String route, [
    Map<String, String> params = const {},
  ]) async {
    final String body;
    try {
      body = await _fetch(apiUrl(route, params)).timeout(timeout);
    } on TimeoutException {
      throw SourceException('MicroDrama: $route timed out');
    }
    return decodeApi(body, route);
  }

  @override
  Future<Paged<Drama>> feed(int page) async {
    // Server-side paging is broken: every page is the same newest 50.
    if (page > 1) return const Paged([], false);
    final j = await _api('list', {'page': '1'});
    return Paged(parseDramaList(j), false);
  }

  @override
  Future<List<Drama>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final j = await _api('search', {'q': q, 'page': '1'});
    return parseDramaList(j);
  }

  @override
  Future<DramaDetail> detail(Drama drama) async =>
      (await _detail(drama.id, fallback: drama)).detail;

  Future<MicroDramaDetail> _detail(
    String id, {
    Drama? fallback,
    bool force = false,
  }) async {
    final cached = _cache[id];
    if (!force && cached != null && cached.isFresh(DateTime.now())) {
      return cached;
    }
    final j = await _api('detail', {'id': id});
    final d = parseDetail(j, fallback: fallback, requestedId: id);
    _cache[id] = d;
    return d;
  }

  @override
  List<String> servers(DramaDetail detail) => const ['1'];

  @override
  Future<EpisodeStream> episode(
    DramaDetail detail,
    int ep, {
    required String server,
  }) async {
    final d = await _detail(detail.id, fallback: detail.toDrama());
    return buildStream(d, ep, server: server);
  }

  // ---------------------------------------------------------------------------
  // Pure parsing (fixture-testable, no WebView).

  /// Decodes an API body; throws [SourceException] on non-JSON (e.g. an HTML
  /// challenge page that slipped through) or an upstream `{"error": ...}`.
  static Map<String, dynamic> decodeApi(String body, String route) {
    final Object? j;
    try {
      j = jsonDecode(body);
    } on FormatException {
      final head = body.trimLeft();
      throw SourceException(
        'MicroDrama: $route returned non-JSON '
        '(${head.length > 60 ? '${head.substring(0, 60)}…' : head})',
      );
    }
    if (j is! Map) {
      throw SourceException('MicroDrama: $route returned unexpected JSON');
    }
    final m = j.cast<String, dynamic>();
    final err = m['error'];
    if (err != null && err.toString().isNotEmpty) {
      throw SourceException('MicroDrama: $route failed: $err');
    }
    return m;
  }

  /// `list` / `search` → `{"total": n, "dramas": [{id,title,description,
  /// episodes,cover}]}`.
  static List<Drama> parseDramaList(Map<String, dynamic> j) {
    final raw = j['dramas'];
    if (raw == null) return const [];
    if (raw is! List) {
      throw SourceException('MicroDrama: "dramas" is not a list');
    }
    final out = <Drama>[];
    final seen = <String>{};
    for (final e in raw) {
      if (e is! Map) continue;
      final id = _str(e['id']);
      final title = _str(e['title']).trim();
      if (id.isEmpty || title.isEmpty || !seen.add(id)) continue;
      final desc = _str(e['description']).trim();
      out.add(
        Drama(
          source: sourceKey,
          id: id,
          title: title,
          cover: _str(e['cover']),
          episodes: _int(e['episodes']) ?? _int(e['total_episodes']),
          synopsis: desc.isEmpty ? null : desc,
        ),
      );
    }
    return out;
  }

  /// `detail` → `{"drama": {...}, "episodes": [{index, videos: [{quality,
  /// url, width, height}]}]}`.
  static MicroDramaDetail parseDetail(
    Map<String, dynamic> j, {
    Drama? fallback,
    String? requestedId,
    DateTime? now,
  }) {
    final drama = j['drama'];
    final eps = j['episodes'];
    if (drama is! Map || eps is! List) {
      throw SourceException(
        'MicroDrama: unexpected detail shape '
        '(keys: ${j.keys.join(', ')})',
      );
    }
    final id = _str(drama['id']).isNotEmpty
        ? _str(drama['id'])
        : (requestedId ?? fallback?.id ?? '');
    if (id.isEmpty) throw SourceException('MicroDrama: detail has no id');

    final videos = <int, List<VideoQuality>>{};
    int? minExpiry;
    for (final e in eps) {
      if (e is! Map) continue;
      final idx = _int(e['index']);
      if (idx == null || idx < 1) continue;
      final qs = parseQualities(e['videos']);
      videos[idx] = qs;
      for (final q in qs) {
        final exp = authKeyExpiry(q.url);
        if (exp != null && (minExpiry == null || exp < minExpiry)) {
          minExpiry = exp;
        }
      }
    }
    if (videos.isEmpty) {
      throw SourceException('MicroDrama: detail has no episodes');
    }
    final indexes = videos.keys.toList()..sort();
    final locked = {
      for (final i in indexes)
        if (videos[i]!.isEmpty) i,
    };
    final total =
        _int(drama['total_episodes']) ??
        _int(drama['episodes']) ??
        indexes.last;

    final title = _str(drama['title']).trim();
    final cover = _str(drama['cover']);
    return MicroDramaDetail(
      DramaDetail(
        source: sourceKey,
        id: id,
        title: title.isNotEmpty ? title : (fallback?.title ?? ''),
        cover: cover.isNotEmpty ? cover : (fallback?.cover ?? ''),
        synopsis: _str(drama['description']).trim().isNotEmpty
            ? _str(drama['description']).trim()
            : (fallback?.synopsis ?? ''),
        totalEpisodes: total < indexes.last ? indexes.last : total,
        episodes: indexes,
        locked: locked,
      ),
      videos,
      fetchedAt: now ?? DateTime.now(),
      expiresAt: minExpiry == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(minExpiry * 1000),
    );
  }

  /// Episode `videos[]` → qualities, best first (720p, 540p, 480p, 360p).
  static List<VideoQuality> parseQualities(Object? raw) {
    if (raw is! List) return const [];
    final items = <({int h, VideoQuality q})>[];
    final seen = <String>{};
    for (final v in raw) {
      if (v is! Map) continue;
      final url = _str(v['url']);
      if (!url.startsWith('http') || !seen.add(url)) continue;
      final qLabel = _str(v['quality']);
      final h = _qualityHeight(qLabel, v);
      final label = h > 0 ? '${h}p' : (qLabel.isEmpty ? 'Auto' : qLabel);
      items.add((h: h, q: VideoQuality(label, url, isHls: false)));
    }
    items.sort((a, b) => b.h.compareTo(a.h));
    return [for (final i in items) i.q];
  }

  /// Build the stream for [ep] from a cached detail. The site plays 720P when
  /// present, else the first listed video; we do the same.
  static EpisodeStream buildStream(
    MicroDramaDetail d,
    int ep, {
    String server = '1',
  }) {
    final qs = d.videos[ep];
    if (qs == null) {
      throw EpisodeLockedException('MicroDrama: episode $ep not found');
    }
    if (qs.isEmpty) {
      throw EpisodeLockedException('MicroDrama: episode $ep has no video');
    }
    final play = qs.firstWhere(
      (q) => q.label == '720p',
      orElse: () => qs.first,
    );
    return EpisodeStream(
      dramaId: d.detail.id,
      ep: ep,
      server: server,
      playUrl: play.url,
      proxyUrl: '',
      isHls: false,
      qualities: qs,
    );
  }

  /// `auth_key=<expiry>-<rand>-0-<md5>` → expiry (epoch seconds).
  static int? authKeyExpiry(String url) {
    final ak = Uri.tryParse(url)?.queryParameters['auth_key'];
    if (ak == null) return null;
    return int.tryParse(ak.split('-').first);
  }

  static int _qualityHeight(String label, Map v) {
    final m = RegExp(r'(\d{3,4})').firstMatch(label);
    if (m != null) return int.parse(m.group(1)!);
    // Portrait video: "720P" means width 720, height 1280.
    final w = _int(v['width']);
    final h = _int(v['height']);
    if (w != null && h != null) return w < h ? w : h;
    return 0;
  }
}

/// Parsed detail plus per-episode video URLs (cached by the source).
class MicroDramaDetail {
  final DramaDetail detail;
  final Map<int, List<VideoQuality>> videos;
  final DateTime fetchedAt;

  /// Earliest `auth_key` expiry across the episode URLs, if parseable.
  final DateTime? expiresAt;

  const MicroDramaDetail(
    this.detail,
    this.videos, {
    required this.fetchedAt,
    this.expiresAt,
  });

  bool isFresh(DateTime now) {
    if (now.difference(fetchedAt) > MicroDramaSource.cacheTtl) return false;
    final exp = expiresAt;
    if (exp != null && now.isAfter(exp.subtract(const Duration(minutes: 10)))) {
      return false;
    }
    return true;
  }
}

String _str(Object? v) => v == null ? '' : v.toString();

int? _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}
