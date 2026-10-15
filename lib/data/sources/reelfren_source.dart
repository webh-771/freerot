// OWNER: catalog agent. ReelFren aggregator (api.reelfren.com) — ~33 short
// drama providers behind one plain-JSON API. Spec: probes/reelfren.md.
//
// Drama.source is 'rf:<provider>' (e.g. 'rf:netshort'); Drama.id is the
// provider's opaque id, passed back verbatim.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models.dart';
import '../ranking.dart' show isPlaceholderIntro;
import '../source.dart';
import 'progressive.dart';
import 'shelf_hooks.dart';

const String kRfApi = 'https://api.reelfren.com';
const String kRfProxy = 'https://proxy.dramafren.org';
const String kRfPrefix = 'rf:';

/// Providers that are broken upstream — never shown.
const Set<String> kRfExcluded = {'filmbox', 'moviebox', 'movieboxshorts'};

/// Feed providers, roughly best/most popular first (also the interleave order).
const List<String> kRfFeedProviders = [
  'netshort', 'dramabox', 'reelshort', 'dramawave', 'kalostv', 'flextv',
  'moboreels', 'vibeshort', 'melolo', 'sereal', 'happyshort', 'shorten',
  'flareflow', 'freereels', 'storyreel', 'blinkdrama', 'dramanova',
  'joyreels', 'reelife', 'rapidtv', 'rapidtv2', 'pinedrama', 'raptdrama',
  'cubetv', 'candyjar', 'bonustv', 'vigloo', 'mydrama', 'anamana', 'flextv2',
  'iqiyi', 'wetv', 'aniboy',
];

/// Providers whose detail lists placeholder episodes (`vid == "$episode"` and
/// `duration == 0`) after the real ones, which /api/video answers with 502.
/// Other providers use that same shape for *every* episode and play fine
/// (blinkdrama, mydrama, reelife, ...), so the rule is opt-in.
const Set<String> kRfPlaceholderProviders = {'vibeshort', 'storyreel'};

/// Providers that serve progressive MP4 (used when `format` is missing).
const Set<String> _mp4Providers = {
  'netshort', 'dramabox', 'anamana', 'dramanova', 'flextv2', 'joyreels',
  'moboreels', 'happyshort', 'reelife', 'sereal', 'rapidtv', 'rapidtv2',
  'pinedrama', 'melolo',
};

const Map<String, String> _labels = {
  'anamana': 'Anamana', 'aniboy': 'AniBoy', 'blinkdrama': 'BlinkDrama',
  'bonustv': 'BonusTV', 'bstation': 'Bstation', 'candyjar': 'CandyJar',
  'cubetv': 'CubeTV', 'dramabox': 'DramaBox', 'dramanova': 'DramaNova',
  'dramawave': 'DramaWave', 'filmbox': 'FilmBox', 'flareflow': 'FlareFlow',
  'flextv': 'FlexTV', 'flextv2': 'FlexTV', 'freereels': 'FreeReels',
  'happyshort': 'HappyShort', 'iqiyi': 'iQIYI', 'joyreels': 'JoyReels',
  'kalostv': 'KalosTV', 'melolo': 'Melolo', 'moboreels': 'MoboReels',
  'moviebox': 'MovieBox', 'movieboxshorts': 'MovieBox Shorts',
  'mydrama': 'MyDrama', 'netshort': 'NetShort', 'pinedrama': 'PineDrama',
  'rapidtv': 'RapidTV', 'rapidtv2': 'RapidTV', 'raptdrama': 'RaptDrama',
  'reelife': 'ReeLife', 'reelshort': 'ReelShort', 'sereal': 'Sereal',
  'shorten': 'Shorten', 'storyreel': 'StoryReel', 'vibeshort': 'VibeShort',
  'vigloo': 'Vigloo', 'wetv': 'WeTV',
};

/// Pretty provider name: "netshort" -> "NetShort"; unknown -> "Foo".
String rfProviderLabel(String provider) {
  final p = provider.toLowerCase();
  final known = _labels[p];
  if (known != null) return known;
  if (p.isEmpty) return 'ReelFren';
  return p[0].toUpperCase() + p.substring(1);
}

String rfProvider(String dramaSource) => dramaSource.startsWith(kRfPrefix)
    ? dramaSource.substring(kRfPrefix.length)
    : dramaSource;

/// Mirror of the site's backendApiAssetUrl(): resolve relative backend URLs.
String rfAbsUrl(String? url) {
  final u = url?.trim() ?? '';
  if (u.isEmpty) return '';
  if (u.startsWith('/api/proxy/')) return '$kRfProxy$u';
  if (u.startsWith('/api/')) return '$kRfApi$u';
  if (u.startsWith('//')) return 'https:$u';
  return u;
}

String? _str(Object? v) {
  if (v == null) return null;
  final s = v.toString().trim();
  return s.isEmpty ? null : s;
}

int _int(Object? v) =>
    v is num ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0;

// ------------------------------------------------------------------ parsing

/// One list item (`/api/home` / `/api/search` data[]). Null if unusable or
/// from an excluded provider.
Drama? parseRfDrama(Object? j) {
  if (j is! Map) return null;
  final provider = _str(j['provider'])?.toLowerCase();
  final id = _str(j['id']);
  final title = _str(j['title']);
  if (provider == null || id == null || title == null) return null;
  if (kRfExcluded.contains(provider)) return null;
  final eps = _int(j['episodes']);
  final intro = _str(j['intro']);
  return Drama(
    source: '$kRfPrefix$provider',
    id: id,
    title: title,
    cover: _str(j['cover']) ?? '',
    episodes: eps > 0 ? eps : null,
    synopsis: (intro == null || isPlaceholderIntro(intro)) ? null : intro,
  );
}

/// `{"data":[...]}` -> dramas (excluded providers dropped, deduped by key).
List<Drama> parseRfList(Object? body) {
  final data = body is Map ? body['data'] : body;
  if (data is! List) return const [];
  final seen = <String>{};
  final out = <Drama>[];
  for (final x in data) {
    final d = parseRfDrama(x);
    if (d != null && seen.add(d.key)) out.add(d);
  }
  return out;
}

/// `/api/detail` -> DramaDetail. [fallback] fills missing title/cover.
DramaDetail parseRfDetail(Object? body, Drama fallback) {
  if (body is! Map) throw SourceException('ReelFren: bad detail response');
  final provider = _str(body['provider'])?.toLowerCase() ??
      rfProvider(fallback.source);
  final videos = body['videos'] is List ? body['videos'] as List : const [];

  var maxEp = 0;
  final placeholders = <int>{};
  var realMax = 0;
  for (final v in videos) {
    if (v is! Map) continue;
    final ep = _int(v['episode']);
    if (ep <= 0) continue;
    if (ep > maxEp) maxEp = ep;
    final isPlaceholder =
        _str(v['vid']) == '$ep' && _int(v['duration']) == 0;
    if (isPlaceholder) {
      placeholders.add(ep);
    } else if (ep > realMax) {
      realMax = ep;
    }
  }
  var total = [_int(body['episodes']), videos.length, maxEp]
      .reduce((a, b) => a > b ? a : b);
  if (total <= 0) total = 1; // movies report 0 episodes

  // Placeholder tail -> locked, but only for providers known to 502 on them
  // and only when real episodes exist (otherwise the shape means nothing).
  final locked = <int>{};
  if (kRfPlaceholderProviders.contains(provider) && realMax > 0) {
    for (final ep in placeholders) {
      if (ep > realMax) locked.add(ep);
    }
    if (locked.isNotEmpty) {
      for (var ep = maxEp + 1; ep <= total; ep++) {
        locked.add(ep);
      }
    }
  }

  final intro = _str(body['intro']);
  return DramaDetail(
    source: '$kRfPrefix$provider',
    id: _str(body['id']) ?? fallback.id,
    title: _str(body['title']) ?? fallback.title,
    cover: _str(body['cover']) ?? fallback.cover,
    synopsis: (intro == null || isPlaceholderIntro(intro))
        ? (fallback.synopsis ?? '')
        : intro,
    totalEpisodes: total,
    episodes: List<int>.generate(total, (i) => i + 1),
    locked: locked,
  );
}

bool _looksHls(String url, String? format, String provider) {
  final f = format?.toLowerCase();
  if (f == 'hls' || f == 'm3u8') return true;
  if (f == 'mp4' || f == 'mpeg4') return false;
  final u = url.toLowerCase();
  if (u.contains('.m3u8') || u.contains('m3u8')) return true;
  if (u.contains('.mp4') || u.contains('mime_type=video_mp4')) return false;
  return !_mp4Providers.contains(provider);
}

final RegExp _resRe = RegExp(r'(\d{3,4})\s*p', caseSensitive: false);

/// Sort key for a quality label: higher = better. HEVC after all H.264
/// (older Android devices can't decode it), "backup" after primaries.
int _qualityRank(String label) {
  final l = label.toLowerCase();
  var r = l.contains('auto')
      ? 5000
      : int.tryParse(_resRe.firstMatch(l)?.group(1) ?? '') ?? 0;
  if (l.contains('265') || l.contains('hevc')) r -= 10000;
  if (l.contains('backup')) r -= 1;
  return r;
}

/// `/api/video` JSON -> EpisodeStream. Throws [EpisodeLockedException] for
/// `locked:true`, [SourceException] if there is no playable URL.
EpisodeStream parseRfVideo(
  Object? body, {
  required String provider,
  required String dramaId,
  required int ep,
  required String server,
}) {
  if (body is! Map) throw SourceException('ReelFren: bad video response');
  if (body['locked'] == true) {
    throw EpisodeLockedException('Episode $ep is locked');
  }

  final entries = <(VideoQuality, int, String)>[]; // quality, index, fallback
  final seen = <String>{};
  final ql = body['qualityList'];
  if (ql is List) {
    for (final q in ql) {
      if (q is! Map) continue;
      final url = rfAbsUrl(_str(q['url']));
      if (url.isEmpty || !seen.add(url)) continue;
      final label = _str(q['label']) ?? 'Auto';
      entries.add((
        VideoQuality(label, url,
            isHls: _looksHls(url, _str(q['format']), provider)),
        entries.length,
        rfAbsUrl(_str(q['fallbackUrl'])),
      ));
    }
  }
  entries.sort((a, b) {
    final c = _qualityRank(b.$1.label).compareTo(_qualityRank(a.$1.label));
    return c != 0 ? c : a.$2.compareTo(b.$2);
  });
  final qualities = [for (final e in entries) e.$1];

  var playUrl = rfAbsUrl(_str(body['videoUrl']));
  if (playUrl.isEmpty && qualities.isNotEmpty) playUrl = qualities.first.url;
  if (playUrl.isEmpty) {
    throw SourceException('ReelFren: no playable URL for episode $ep');
  }
  final match = entries.where((e) => e.$1.url == playUrl).firstOrNull;
  final isHls = match?.$1.isHls ?? _looksHls(playUrl, null, provider);

  final subs = <Subtitle>[];
  final sl = body['subtitles'];
  if (sl is List) {
    for (final s in sl) {
      if (s is! Map) continue;
      final url = rfAbsUrl(_str(s['url']));
      if (url.isEmpty) continue;
      final lang = _str(s['srclang']) ?? _str(s['lang']) ?? '';
      subs.add(Subtitle(_str(s['label']) ?? lang, lang, url));
    }
  }
  bool isEn(Subtitle s) =>
      s.lang.toLowerCase().startsWith('en') ||
      s.label.toLowerCase().contains('english');
  final subtitles = [...subs.where(isEn), ...subs.where((s) => !isEn(s))];

  return EpisodeStream(
    dramaId: dramaId,
    ep: ep,
    server: server,
    playUrl: playUrl,
    proxyUrl: match?.$3 ?? '',
    isHls: isHls,
    qualities: qualities,
    subtitles: subtitles,
  );
}

// ------------------------------------------------------------------- source

class _Cursor {
  final String provider;
  int nextOffset = 0;
  bool exhausted = false;
  int failures = 0;
  final List<Drama> buffer = [];
  final Set<String> seen = {};
  Future<void>? refill;
  _Cursor(this.provider);
}

/// Serialises async calls (feed pages mutate shared cursor state).
class _Serial {
  Future<void> _tail = Future.value();
  Future<T> run<T>(Future<T> Function() f) {
    final r = _tail.then((_) => f());
    _tail = r.then((_) {}, onError: (_) {});
    return r;
  }
}

/// Simple counting semaphore for outbound feed calls.
class _Pool {
  final int max;
  int _active = 0;
  final List<Completer<void>> _waiters = [];
  _Pool(this.max);
  Future<T> run<T>(Future<T> Function() f) async {
    if (_active >= max) {
      final c = Completer<void>();
      _waiters.add(c);
      await c.future;
    }
    _active++;
    try {
      return await f();
    } finally {
      _active--;
      if (_waiters.isNotEmpty) _waiters.removeAt(0).complete();
    }
  }
}

/// Providers whose listing is newest-first, with the `/api/home` category
/// to ask for (null = default home). Checked live 2026-09: netshort ids are
/// increasing snowflakes and its home is in id-descending order; flextv's
/// default home *is* its "newest" tab; shorten has a "releases" tab.
/// Other providers' home order is unknown (feed=latest has no effect).
const Map<String, String?> kRfNewestLanes = {
  'netshort': null,
  'flextv': 'newest',
  'shorten': 'releases',
};

/// Numeric-string compare (snowflake ids exceed 2^53 on the web).
int compareNumericIds(String a, String b) {
  final ai = BigInt.tryParse(a), bi = BigInt.tryParse(b);
  if (ai != null && bi != null) return ai.compareTo(bi);
  return a.compareTo(b);
}

class ReelFrenSource extends DramaSource
    implements ProgressiveSearch, NewestFeed {
  ReelFrenSource({
    http.Client? client,
    List<String>? providers,
    this.lang = 'en',
    this.itemsPerProvider = 2,
    this.pageBudget = const Duration(seconds: 10),
  })  : _client = client ?? http.Client(),
        providers = [
          for (final p in providers ?? kRfFeedProviders)
            if (!kRfExcluded.contains(p)) p,
        ];

  final http.Client _client;
  final String lang;

  /// Feed providers (interleave order).
  final List<String> providers;

  /// Items taken from each provider per feed page (~33 providers -> ~66).
  final int itemsPerProvider;

  /// Max time a feed page waits for provider refills.
  final Duration pageBudget;

  static const Duration _callTimeout = Duration(seconds: 10);
  static const Duration _searchTimeout = Duration(seconds: 12);
  static const Duration _videoTimeout = Duration(seconds: 15);
  static const String _ua =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/124.0 Mobile Safari/537.36';

  final Map<String, Future<List<Drama>>> _homeCache = {};
  final _Serial _serial = _Serial();
  final _Pool _pool = _Pool(6);
  List<_Cursor>? _cursors;
  final Map<int, Paged<Drama>> _pages = {};

  @override
  String get key => 'reelfren';

  @override
  bool handles(String dramaSource) => dramaSource.startsWith(kRfPrefix);

  @override
  String label(String dramaSource) => rfProviderLabel(rfProvider(dramaSource));

  @override
  int get feedWeight => 3;

  // -------------------------------------------------------------- feed

  @override
  Future<Paged<Drama>> feed(int page) => _serial.run(() => _feed(page));

  Future<Paged<Drama>> _feed(int page) async {
    if (page <= 1 || _cursors == null) {
      _cursors = [for (final p in providers) _Cursor(p)];
      _pages.clear();
    }
    final done = _pages[page];
    if (done != null) return done;
    final cursors = _cursors!;

    final waits = <Future<void>>[];
    for (final c in cursors) {
      if (c.exhausted || c.buffer.length >= itemsPerProvider) continue;
      waits.add(c.refill ??= _refill(c).whenComplete(() => c.refill = null));
    }
    if (waits.isNotEmpty) {
      await Future.wait(waits).timeout(pageBudget, onTimeout: () => const []);
    }

    final out = <Drama>[];
    for (var round = 0; round < itemsPerProvider; round++) {
      for (final c in cursors) {
        if (c.buffer.isNotEmpty) out.add(c.buffer.removeAt(0));
      }
    }
    final hasMore = cursors.any(
      (c) => !c.exhausted || c.buffer.isNotEmpty || c.refill != null,
    );
    final result = Paged<Drama>(out, hasMore);
    _pages[page] = result;
    return result;
  }

  Future<void> _refill(_Cursor c) async {
    try {
      List<Drama> list;
      try {
        list = await _pool.run(() => _home(c.provider, c.nextOffset));
      } on SourceException {
        // Transient 5xx / connection resets happen under bursts: retry once.
        await Future<void>.delayed(const Duration(milliseconds: 400));
        list = await _pool.run(() => _home(c.provider, c.nextOffset));
      }
      final fresh = list.where((d) => c.seen.add(d.key)).toList();
      if (fresh.isEmpty) {
        // [] (end) or the same page again (dramabox ignores offset).
        c.exhausted = true;
        return;
      }
      c.buffer.addAll(fresh);
      // Providers that dump their whole catalogue on offset 0 return [] for
      // later offsets — don't bother asking.
      if (c.nextOffset == 0 && list.length > 40) c.exhausted = true;
      c.nextOffset++;
    } catch (_) {
      if (++c.failures >= 2) c.exhausted = true;
    }
  }

  // ------------------------------------------------------------ newest

  @override
  List<String> get newestLanes => [
        for (final p in kRfNewestLanes.keys)
          if (providers.contains(p)) p,
      ];

  /// Newest-first page of one provider (see [kRfNewestLanes]).
  @override
  Future<Paged<Drama>> newest(String lane, int page) async {
    if (!kRfNewestLanes.containsKey(lane)) return const Paged([], false);
    final list = await _pool.run(
      () => _home(lane, page < 1 ? 0 : page - 1, category: kRfNewestLanes[lane]),
    );
    final items = [...list];
    if (lane == 'netshort') {
      items.sort((a, b) => compareNumericIds(b.id, a.id));
    }
    return Paged(items, items.isNotEmpty);
  }

  /// `/api/home?provider=P&offset=N[&category=C]` (cached per
  /// provider+offset+category).
  Future<List<Drama>> _home(String provider, int offset, {String? category}) {
    final k = '$lang|$provider|$offset|${category ?? ''}';
    return _homeCache[k] ??= () async {
      try {
        final body = await _getJson(
          '/api/home',
          {
            'provider': provider,
            'offset': '$offset',
            'category': ?category,
            'lang': lang,
          },
          _callTimeout,
        );
        return parseRfList(body);
      } catch (_) {
        _homeCache.remove(k);
        rethrow;
      }
    }();
  }

  // ------------------------------------------------------------ search

  /// All results once every provider answered (or timed out).
  @override
  Future<List<Drama>> search(String query) async {
    final seen = <String>{};
    final out = <Drama>[];
    await for (final chunk in searchChunks(query)) {
      out.addAll(chunk.where((d) => seen.add(d.key)));
    }
    return out;
  }

  /// Per-provider `/api/search?provider=P` fan-out, one chunk per provider
  /// as it answers. The global (provider-less) endpoint waits for the
  /// slowest provider (13–20 s uncached); per provider most answer in
  /// < 1.5 s and all within ~6 s.
  @override
  Stream<List<Drama>> searchChunks(String query) {
    final q = query.trim();
    final ctrl = StreamController<List<Drama>>();
    if (q.isEmpty) {
      ctrl.close();
      return ctrl.stream;
    }
    final pool = _Pool(12);
    var cancelled = false;
    ctrl.onCancel = () => cancelled = true;
    ctrl.onListen = () async {
      await Future.wait([
        for (final p in providers)
          pool.run(() async {
            if (cancelled) return;
            try {
              final body = await _getJson(
                '/api/search',
                {'q': q, 'lang': lang, 'offset': '0', 'provider': p},
                _searchTimeout,
              );
              final items = parseRfList(body);
              if (!cancelled && items.isNotEmpty) ctrl.add(items);
            } catch (_) {
              // one provider failing is fine
            }
          }),
      ]);
      await ctrl.close();
    };
    return ctrl.stream;
  }

  // ------------------------------------------------------ detail / play

  @override
  Future<DramaDetail> detail(Drama drama) async {
    final provider = rfProvider(drama.source);
    final params = {'provider': provider, 'id': drama.id, 'lang': lang};
    Object? body;
    try {
      body = await _getJson('/api/detail', params, _callTimeout);
    } on SourceException catch (e) {
      if (e is _HttpStatus && e.status >= 500) {
        body = await _getJson('/api/detail', params, _callTimeout);
      } else {
        rethrow;
      }
    }
    return parseRfDetail(body, drama);
  }

  @override
  List<String> servers(DramaDetail detail) => const ['1', 'refresh'];

  @override
  Future<EpisodeStream> episode(
    DramaDetail detail,
    int ep, {
    required String server,
  }) async {
    if (detail.locked.contains(ep)) {
      throw EpisodeLockedException('Episode $ep is not available');
    }
    final provider = rfProvider(detail.source);
    final params = {
      'provider': provider,
      'id': detail.id,
      'ep': '$ep',
      'lang': lang,
      'server': '1',
      'cv': 'v21',
      if (server == 'refresh') 'refresh': '1',
      if (server == 'refresh') 'rt': '${DateTime.now().millisecondsSinceEpoch}',
    };
    final Object? body;
    try {
      body = await _getJson('/api/video', params, _videoTimeout);
    } on _HttpStatus catch (e) {
      if (e.status == 502) {
        throw EpisodeLockedException('Episode $ep is not available');
      }
      rethrow;
    }
    return parseRfVideo(
      body,
      provider: provider,
      dramaId: detail.id,
      ep: ep,
      server: server,
    );
  }

  // ------------------------------------------------------------ http

  Future<Object?> _getJson(
    String path,
    Map<String, String> params,
    Duration timeout,
  ) async {
    final uri = Uri.parse('$kRfApi$path').replace(queryParameters: params);
    final http.Response res;
    try {
      res = await _client.get(
        uri,
        headers: {'User-Agent': _ua, 'Accept': 'application/json'},
      ).timeout(timeout);
    } on TimeoutException {
      throw SourceException('ReelFren $path timed out');
    } catch (e) {
      throw SourceException('ReelFren network error ($path): $e');
    }
    if (res.statusCode != 200) {
      final html = (res.headers['content-type'] ?? '').contains('text/html');
      if (res.statusCode == 403 && html) {
        throw _HttpStatus(403, 'ReelFren is blocked by a Cloudflare challenge');
      }
      throw _HttpStatus(res.statusCode, 'ReelFren $path: HTTP ${res.statusCode}');
    }
    try {
      return jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      throw SourceException('ReelFren $path: invalid JSON');
    }
  }
}

class _HttpStatus extends SourceException {
  final int status;
  _HttpStatus(this.status, super.message);
}
