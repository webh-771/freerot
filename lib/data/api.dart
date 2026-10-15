// OWNER: data agent. Public signatures are a contract used by UI + player.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models.dart';
import 'official_crypto.dart';
import 'parsers.dart';

export 'parsers.dart' show Category, ShortMaxException, kShortMaxSource;

class ShortMaxApi {
  ShortMaxApi._();
  static final ShortMaxApi instance = ShortMaxApi._();

  /// Content language for site + official API ("en", "id", "ja", ...).
  String lang = 'en';

  static const String _userAgent =
      'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';
  static const String _officialBase =
      'https://shortweb.shorttv.live/app-api/app/';
  static const List<String> _videoEndpoints = [
    'https://cdn-shortmaxv3.dramafren.org/index.php',
    'https://cdn-shortmaxv5.dramafren.org/index.php',
  ];
  static const int _pageSize = 24;
  static const Duration _timeout = Duration(seconds: 15);

  /// Unfiltered `queryPage` routinely takes ~12 s server-side.
  static const Duration _officialTimeout = Duration(seconds: 35);
  static const Duration _browseTtl = Duration(minutes: 10);
  static const Duration _videoTimeout = Duration(seconds: 7);

  final http.Client _client = http.Client();
  final Map<String, DramaDetail> _detailCache = {};
  final Map<String, List<Category>> _categoryCache = {};
  final Map<String, (DateTime, Paged<Drama>)> _browseCache = {};
  final Map<String, Future<Paged<Drama>>> _browseInFlight = {};
  final Map<String, Future<List<Category>>> _categoryInFlight = {};

  /// Largest page the official API accepts.
  static const int maxPageSize = 100;

  /// Real play counts seen in official responses, by `lang|id` (so site
  /// search / history cards can carry them too).
  final Map<String, int> _views = {};

  /// Official catalogue (shorttv queryPage). [classId] filters by category.
  /// Items carry [Drama.views] (`playNum`). [pageSize] is capped at 100.
  /// Results are cached in memory for 10 minutes (the endpoint is slow).
  Future<Paged<Drama>> browse({
    int page = 1,
    int? classId,
    int pageSize = _pageSize,
  }) {
    final size = pageSize.clamp(1, maxPageSize);
    final key = '$lang|${classId ?? ''}|$page'
        '${size == _pageSize ? '' : '|$size'}';
    final hit = _browseCache[key];
    if (hit != null && DateTime.now().difference(hit.$1) < _browseTtl) {
      return Future.value(hit.$2);
    }
    final l = lang;
    return _browseInFlight[key] ??= () async {
      try {
        final data = await _official('cmsShortPlay/queryPage', {
          'pageNo': page,
          'pageSize': size,
          'classId': ?classId,
        });
        final result = parseOfficialPage(data, page, size);
        for (final d in result.items) {
          if (d.views != null) _views['$l|${d.id}'] = d.views!;
        }
        _browseCache[key] = (DateTime.now(), result);
        return result;
      } finally {
        _browseInFlight.remove(key);
      }
    }();
  }

  /// Official categories (cmsClassNew/queryList).
  Future<List<Category>> categories() {
    final key = lang;
    final cached = _categoryCache[key];
    if (cached != null) return Future.value(cached);
    return _categoryInFlight[key] ??= () async {
      try {
        final data = await _official('cmsClassNew/queryList', const {});
        final list = List<Category>.unmodifiable(parseCategories(data));
        _categoryCache[key] = list;
        return list;
      } finally {
        _categoryInFlight.remove(key);
      }
    }();
  }

  /// [d] with its real view count filled in from any official response seen
  /// so far (site cards don't carry one). Unchanged if unknown.
  Drama withViews(Drama d) {
    if (d.views != null || d.source != kShortMaxSource) return d;
    final v = _views['$lang|${d.id}'];
    if (v == null) return d;
    return Drama(
      source: d.source,
      id: d.id,
      title: d.title,
      cover: d.cover,
      episodes: d.episodes,
      synopsis: d.synopsis,
      views: v,
    );
  }

  /// Every official item currently in the browse cache (no network).
  List<Drama> cachedOfficial() {
    final now = DateTime.now();
    final seen = <String>{};
    return [
      for (final e in _browseCache.entries)
        if (e.key.startsWith('$lang|') &&
            now.difference(e.value.$1) < _browseTtl)
          for (final d in e.value.$2.items)
            if (seen.add(d.id)) d,
    ];
  }

  static const Duration _catalogueTtl = Duration(minutes: 30);
  final Map<String, (DateTime, List<Drama>)> _catalogueCache = {};
  final Map<String, Future<List<Drama>>> _catalogueInFlight = {};

  /// The whole official catalogue (~1000 titles, default order = newest
  /// first), fetched as 100-item pages in parallel (~15-20 s cold; each
  /// page is as slow as a small one). Cached for 30 minutes; a load with a
  /// failed page returns what it got but is not cached.
  Future<List<Drama>> catalogue() {
    final key = lang;
    final hit = _catalogueCache[key];
    if (hit != null && DateTime.now().difference(hit.$1) < _catalogueTtl) {
      return Future.value(hit.$2);
    }
    return _catalogueInFlight[key] ??= () async {
      try {
        return await _loadCatalogue(key);
      } finally {
        _catalogueInFlight.remove(key);
      }
    }();
  }

  /// The catalogue if it is loaded and fresh, else null.
  List<Drama>? cachedCatalogue() {
    final hit = _catalogueCache[lang];
    if (hit == null ||
        DateTime.now().difference(hit.$1) >= _catalogueTtl) {
      return null;
    }
    return hit.$2;
  }

  /// Pages guessed for the first parallel burst (the catalogue had 1022
  /// titles in 2026-09); the rest is fetched once the last one says more.
  int _cataloguePages = 11;

  Future<List<Drama>> _loadCatalogue(String key) async {
    final pages = <int, Paged<Drama>>{};
    var failed = 0;
    Future<void> fetch(int p) async {
      try {
        pages[p] = await browse(page: p, pageSize: maxPageSize);
      } catch (_) {
        failed++;
      }
    }

    var upTo = _cataloguePages;
    await Future.wait([for (var p = 1; p <= upTo; p++) fetch(p)]);
    while ((pages[upTo]?.hasMore ?? false) && upTo < 60) {
      final from = upTo + 1;
      upTo += 4;
      await Future.wait([for (var p = from; p <= upTo; p++) fetch(p)]);
    }
    if (pages.isEmpty) {
      throw const ShortMaxException('Could not load the official catalogue');
    }
    final last = pages.entries
        .where((e) => e.value.items.isNotEmpty)
        .fold(0, (m, e) => e.key > m ? e.key : m);
    if (last > 0) _cataloguePages = last;
    final seen = <String>{};
    final out = List<Drama>.unmodifiable([
      for (final p in pages.keys.toList()..sort())
        for (final d in pages[p]!.items)
          if (seen.add(d.id)) d,
    ]);
    if (failed == 0) _catalogueCache[key] = (DateTime.now(), out);
    return out;
  }

  /// Site search (`page=search_result&q=&s_page=`).
  Future<Paged<Drama>> search(String query, {int page = 1}) async {
    final q = query.trim();
    if (q.isEmpty) return const Paged([], false);
    final html = await _site({
      'page': 'search_result',
      'q': q,
      'lang': lang,
      's_page': '$page',
    });
    return _parse('search', () => parseSearch(html, page));
  }

  /// Site "Recently Watched" feed (`page=home&p_hist=`) — what others watch.
  Future<Paged<Drama>> siteRecent({int page = 1}) async {
    final html = await _site({'page': 'home', 'p_hist': '$page', 'lang': lang});
    return _parse('recent', () => parseRecent(html, page));
  }

  /// Site drama page (`page=detail&id=`).
  Future<DramaDetail> detail(String id) async {
    final key = '$lang|$id';
    final cached = _detailCache[key];
    if (cached != null) return cached;
    final html = await _site({'page': 'detail', 'id': id, 'lang': lang});
    final d = _parse('detail', () => parseDetail(html, id));
    _detailCache[key] = d;
    return d;
  }

  /// Resolve m3u8 for an episode. Tries cdn-shortmaxv3 then v5 endpoints.
  Future<EpisodeStream> episode(
    String id,
    int ep, {
    String server = 'server1',
  }) async {
    final errors = <String>[];
    for (final base in _videoEndpoints) {
      final uri = Uri.parse(base).replace(
        queryParameters: {
          'action': 'video_server',
          'server': server,
          'id': id,
          'ep': '$ep',
          'lang': lang,
          'stale': '1',
        },
      );
      try {
        final res = await _client
            .get(
              uri,
              headers: {'User-Agent': _userAgent, 'Accept': 'application/json'},
            )
            .timeout(_videoTimeout);
        if (res.statusCode != 200) {
          throw ShortMaxException('HTTP ${res.statusCode}');
        }
        return parseEpisodeStream(_body(res), id, ep, server);
      } on ShortMaxException catch (e) {
        errors.add('${uri.host}: ${e.message}');
      } on TimeoutException {
        errors.add('${uri.host}: timed out');
      } catch (e) {
        errors.add('${uri.host}: $e');
      }
    }
    throw ShortMaxException(
      'Could not resolve $id ep $ep on $server (${errors.join('; ')})',
    );
  }

  // ---------------------------------------------------------------- helpers

  String _body(http.Response res) {
    try {
      return utf8.decode(res.bodyBytes);
    } catch (_) {
      return res.body;
    }
  }

  T _parse<T>(String what, T Function() fn) {
    try {
      return fn();
    } on ShortMaxException {
      rethrow;
    } catch (e) {
      throw ShortMaxException('Failed to parse $what page: $e');
    }
  }

  Future<String> _site(Map<String, String> params) async {
    final uri = Uri.parse(kSiteBase).replace(queryParameters: params);
    final http.Response res;
    try {
      res = await _client
          .get(
            uri,
            headers: {
              'User-Agent': _userAgent,
              'Accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
              'Accept-Language': '$lang,en;q=0.8',
            },
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw ShortMaxException('Request timed out: ${params['page']}');
    } catch (e) {
      throw ShortMaxException('Network error (${params['page']}): $e');
    }
    if (res.statusCode != 200) {
      throw ShortMaxException(
        'HTTP ${res.statusCode} for site page ${params['page']}',
      );
    }
    return _body(res);
  }

  Future<Object?> _official(String path, Map<String, Object?> payload) async {
    final http.Response res;
    try {
      res = await _client
          .post(
            Uri.parse('$_officialBase$path'),
            headers: {
              'Content-Type': 'application/json',
              'X-Encrypted': 'true',
              'Language-Code': lang,
              'User-Agent': _userAgent,
            },
            body: officialEncrypt(payload),
          )
          .timeout(_officialTimeout);
    } on TimeoutException {
      throw ShortMaxException('Request timed out: $path');
    } catch (e) {
      throw ShortMaxException('Network error ($path): $e');
    }
    if (res.statusCode != 200) {
      throw ShortMaxException('HTTP ${res.statusCode} for $path');
    }
    final Object? decoded;
    try {
      decoded = officialDecrypt(_body(res));
    } catch (e) {
      throw ShortMaxException('Could not decrypt $path response: $e');
    }
    if (decoded is! Map) {
      throw ShortMaxException('Unexpected $path response');
    }
    final code = decoded['code'];
    if (code != 0 && code != '0') {
      throw ShortMaxException(
        '$path failed (code $code): ${decoded['msg'] ?? 'unknown error'}',
      );
    }
    return decoded['data'];
  }
}
