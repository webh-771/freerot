// shortwave.dramafren.org — ShortsWave catalogue (see probes/shortwave.md).
//
// All JSON comes from `GET https://shortwave.dramafren.org/?api_route=<route>
// &lang=en&...`, which sits behind a Cloudflare managed challenge, so every API
// call goes through [WebSession.get] (same-origin fetch inside a WebView; the
// user completes the challenge in a popup). [NeedsVerificationException] is
// propagated unchanged so the UI can show the verify banner.
//
// Playback: `unlock` returns base64(play URL) =
// https://api.shortswave.com/v1/play/<chapter_id>/v.m3u8?auth_key=… which is
// CF-free, needs no headers, and works for `is_free:0` episodes too. Streams
// are plain HLS with HEVC 720p .ts segments (very old / low-end devices may
// fail to decode them).
//
// Quirks:
// - `list` is 24/page (~100 pages for en); past the end the server repeats the
//   last page, so hasMore = full page && not a repeat of the previous page.
// - `search` returns at most 20 hits and ignores paging.
// - Detail episodes aren't sorted; `index` (1-based) is the episode number.
import 'dart:async';
import 'dart:convert';

import '../../models.dart';
import '../source.dart';
import '../web/web_session.dart';
import 'shelf_hooks.dart';

class ShortWaveSource extends DramaSource implements SessionGated {
  static const sourceKey = 'shortwave';
  static const host = 'shortwave.dramafren.org';
  static const origin = 'https://$host';
  static const lang = 'en';
  static const pageSize = 24;
  static const maxPages = 300;
  static const timeout = Duration(seconds: 20);

  final Future<String> Function(String url) _fetch;

  ShortWaveSource({Future<String> Function(String url)? fetch})
    : _fetch = fetch ?? ((url) => WebSession.instance.get(url));

  /// dramaId → (episode index → chapter_id).
  final Map<String, Map<int, String>> _chapters = {};

  /// page → ids on that page, to detect the server repeating the last page.
  final Map<int, List<String>> _pageIds = {};

  @override
  String get key => sourceKey;

  @override
  bool handles(String dramaSource) => dramaSource == sourceKey;

  @override
  String label(String dramaSource) => 'ShortWave';

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
      throw SourceException('ShortWave: $route timed out');
    }
    return decodeApi(body, route);
  }

  @override
  Future<Paged<Drama>> feed(int page) async {
    if (page < 1 || page > maxPages) return const Paged([], false);
    final j = await _api('list', {'page': '$page'});
    final items = parseDramaList(j);
    final ids = [for (final d in items) d.id];
    _pageIds[page] = ids;
    if (isRepeatPage(ids, _pageIds[page - 1])) {
      return const Paged([], false);
    }
    return Paged(items, items.length >= pageSize);
  }

  @override
  Future<List<Drama>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final j = await _api('search', {'q': q, 'page': '1'});
    return parseDramaList(j);
  }

  @override
  Future<DramaDetail> detail(Drama drama) async {
    final j = await _api('detail', {'id': drama.id});
    final d = parseDetail(j, fallback: drama, requestedId: drama.id);
    _chapters[d.detail.id] = d.chapters;
    return d.detail;
  }

  @override
  List<String> servers(DramaDetail detail) => const ['1'];

  @override
  Future<EpisodeStream> episode(
    DramaDetail detail,
    int ep, {
    required String server,
  }) async {
    var chapters = _chapters[detail.id];
    if (chapters == null || !chapters.containsKey(ep)) {
      await this.detail(detail.toDrama());
      chapters = _chapters[detail.id];
    }
    final chapterId = chapters?[ep];
    if (chapterId == null) {
      throw EpisodeLockedException('ShortWave: episode $ep not found');
    }
    final j = await _api('unlock', {
      'drama_id': detail.id,
      'chapter_id': chapterId,
    });
    return parseUnlock(j, dramaId: detail.id, ep: ep, server: server);
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
        'ShortWave: $route returned non-JSON '
        '(${head.length > 60 ? '${head.substring(0, 60)}…' : head})',
      );
    }
    if (j is! Map) {
      throw SourceException('ShortWave: $route returned unexpected JSON');
    }
    final m = j.cast<String, dynamic>();
    final err = m['error'];
    if (err != null && err.toString().isNotEmpty) {
      throw SourceException('ShortWave: $route failed: $err');
    }
    return m;
  }

  /// True when [ids] is the same page as [prev] (server repeats the last page
  /// past the end).
  static bool isRepeatPage(List<String> ids, List<String>? prev) {
    if (prev == null || ids.isEmpty || ids.length != prev.length) return false;
    for (var i = 0; i < ids.length; i++) {
      if (ids[i] != prev[i]) return false;
    }
    return true;
  }

  /// `list` / `search` → `{"dramas": [{id, cover, title, episodes}]}`.
  static List<Drama> parseDramaList(Map<String, dynamic> j) {
    final raw = j['dramas'];
    if (raw == null) return const [];
    if (raw is! List) {
      throw SourceException('ShortWave: "dramas" is not a list');
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
          episodes: _int(e['episodes']),
          synopsis: desc.isEmpty ? null : desc,
        ),
      );
    }
    return out;
  }

  /// `detail` → `{"drama": {id,title,description,cover}, "episodes":
  /// [{index, chapter_id, is_free}]}`.
  static ShortWaveDetail parseDetail(
    Map<String, dynamic> j, {
    Drama? fallback,
    String? requestedId,
  }) {
    final drama = j['drama'];
    final eps = j['episodes'];
    if (drama is! Map || eps is! List) {
      throw SourceException(
        'ShortWave: unexpected detail shape '
        '(keys: ${j.keys.join(', ')})',
      );
    }
    final id = _str(drama['id']).isNotEmpty
        ? _str(drama['id'])
        : (requestedId ?? fallback?.id ?? '');
    if (id.isEmpty) throw SourceException('ShortWave: detail has no id');

    final chapters = <int, String>{};
    final paid = <int>{};
    for (final e in eps) {
      if (e is! Map) continue;
      final idx = _int(e['index']);
      final cid = _str(e['chapter_id']);
      if (idx == null || idx < 1 || cid.isEmpty) continue;
      chapters[idx] = cid;
      if (_int(e['is_free']) == 0) paid.add(idx);
    }
    if (chapters.isEmpty) {
      throw SourceException('ShortWave: detail has no episodes');
    }
    final indexes = chapters.keys.toList()..sort();
    final total = _int(drama['episodes']) ?? fallback?.episodes ?? indexes.last;

    final title = _str(drama['title']).trim();
    final cover = _str(drama['cover']);
    final desc = _str(drama['description']).trim();
    return ShortWaveDetail(
      DramaDetail(
        source: sourceKey,
        id: id,
        title: title.isNotEmpty ? title : (fallback?.title ?? ''),
        cover: cover.isNotEmpty ? cover : (fallback?.cover ?? ''),
        synopsis: desc.isNotEmpty ? desc : (fallback?.synopsis ?? ''),
        totalEpisodes: total < indexes.last ? indexes.last : total,
        episodes: indexes,
        // is_free:0 episodes still unlock, so nothing is locked.
      ),
      chapters,
      paid,
    );
  }

  /// `unlock` → EpisodeStream. The play URL is base64 in `play_url_encoded`
  /// (falls back to plain `play_url_720p` if the site ever fills it).
  static EpisodeStream parseUnlock(
    Map<String, dynamic> j, {
    required String dramaId,
    required int ep,
    String server = '1',
  }) {
    final code = _int(j['code']);
    final data = j['data'];
    if (code != null && code != 0) {
      throw SourceException(
        'ShortWave: unlock ep $ep failed '
        '(code $code${_str(j['msg']).isEmpty ? '' : ': ${j['msg']}'})',
      );
    }
    if (data is! Map) {
      throw SourceException(
        'ShortWave: unexpected unlock shape '
        '(keys: ${j.keys.join(', ')})',
      );
    }
    var url = decodePlayUrl(_str(data['play_url_encoded']));
    if (url == null || url.isEmpty) {
      final plain = _str(data['play_url_720p']);
      if (plain.startsWith('http')) url = plain;
    }
    if (url == null || url.isEmpty) {
      throw EpisodeLockedException('ShortWave: no play URL for episode $ep');
    }

    final subs = <Subtitle>[];
    final sublist = data['sublist'];
    if (sublist is List) {
      for (final s in sublist) {
        if (s is! Map) continue;
        final u = _str(s['url']);
        // Player expects WebVTT; skip anything else.
        if (!u.startsWith('http') || !u.toLowerCase().contains('.vtt')) {
          continue;
        }
        final language = _str(s['language']);
        final code = _str(s['languageId']);
        subs.add(
          Subtitle(
            language.isEmpty ? 'Subtitles' : language,
            code.isEmpty ? language : code,
            u,
          ),
        );
      }
    }

    return EpisodeStream(
      dramaId: dramaId,
      ep: ep,
      server: server,
      playUrl: url,
      proxyUrl: '',
      isHls: true,
      qualities: [VideoQuality('720p', url, isHls: true)],
      subtitles: subs,
    );
  }

  /// base64 (standard or url-safe, padding optional) → http(s) URL, or null.
  static String? decodePlayUrl(String encoded) {
    final s = encoded.trim();
    if (s.isEmpty) return null;
    if (s.startsWith('http')) return s;
    try {
      final norm = base64.normalize(
        s.replaceAll('-', '+').replaceAll('_', '/'),
      );
      final url = utf8.decode(base64.decode(norm)).trim();
      if (!url.startsWith('http')) {
        throw SourceException('ShortWave: decoded play URL is not http(s)');
      }
      return url;
    } on FormatException {
      throw SourceException('ShortWave: play_url_encoded is not base64');
    }
  }
}

/// Parsed detail plus episode index → chapter_id (and which were paywalled).
class ShortWaveDetail {
  final DramaDetail detail;
  final Map<int, String> chapters;

  /// Episodes marked `is_free:0` upstream (they still unlock; informational).
  final Set<int> paid;

  const ShortWaveDetail(this.detail, this.chapters, this.paid);
}

String _str(Object? v) => v == null ? '' : v.toString();

int? _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}
