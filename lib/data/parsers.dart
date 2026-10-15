// OWNER: data agent. Pure parsing helpers for the ShortMax site / APIs.
// Kept free of network code so they can be unit-tested against fixtures.
import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../models.dart';

/// Base URL of the server-rendered site (relative links resolve against it).
const String kSiteBase = 'https://shortmax.ngeshorts.fun/index.php';

/// [Drama.source] key for everything this client returns.
const String kShortMaxSource = 'shortmax';

/// An official ShortMax category (cmsClassNew/queryList).
class Category {
  final int classId;
  final String name;
  const Category(this.classId, this.name);
}

/// Error raised by [ShortMaxApi] for HTTP, JSON or HTML parse failures.
class ShortMaxException implements Exception {
  final String message;
  const ShortMaxException(this.message);
  @override
  String toString() => 'ShortMaxException: $message';
}

final Uri _siteBaseUri = Uri.parse(kSiteBase);

/// Resolves a possibly relative URL against the site base.
String resolveSiteUrl(String? url) {
  final u = url?.trim() ?? '';
  if (u.isEmpty) return '';
  if (u.startsWith('//')) return 'https:$u';
  try {
    return _siteBaseUri.resolve(u).toString();
  } catch (_) {
    return u;
  }
}

final RegExp _entityRe = RegExp(
  r'&(#\d+|#x[0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);',
);

/// Decodes any HTML entities left in [s] (e.g. `&#039;` in JSON-LD) and
/// collapses whitespace.
String decodeEntities(String s) {
  var out = s;
  if (_entityRe.hasMatch(out)) {
    out = html_parser.parseFragment(out).text ?? out;
  }
  return out.replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _text(dom.Element? e) => e == null ? '' : decodeEntities(e.text);

/// Query parameters of a site href (handles relative `index.php?...`).
Map<String, String> _hrefParams(String? href) {
  if (href == null || href.isEmpty) return const {};
  try {
    return _siteBaseUri.resolve(href.trim()).queryParameters;
  } catch (_) {
    return const {};
  }
}

int? _int(String? s) => s == null ? null : int.tryParse(s.trim());

Map<String, dynamic>? _jsonLd(dom.Document doc) {
  for (final s in doc.querySelectorAll('script[type="application/ld+json"]')) {
    try {
      final v = jsonDecode(s.text);
      if (v is Map<String, dynamic>) return v;
    } catch (_) {}
  }
  return null;
}

String? _meta(dom.Document doc, String key) {
  final e =
      doc.querySelector('meta[property="$key"]') ??
      doc.querySelector('meta[name="$key"]');
  final c = e?.attributes['content'];
  return (c == null || c.trim().isEmpty) ? null : decodeEntities(c);
}

/// Parses a site detail page (`page=detail&id=`).
DramaDetail parseDetail(String html, String id) {
  final doc = html_parser.parse(html);
  final ld = _jsonLd(doc);
  final h1 = doc.querySelector('h1');

  var title = _text(h1);
  if (title.isEmpty && ld?['headline'] is String) {
    title = decodeEntities(ld!['headline'] as String);
  }
  if (title.isEmpty) {
    throw ShortMaxException('Drama $id not found (no title on detail page)');
  }

  // Cover: the poster <img> nearest the title, else JSON-LD / og:image.
  String cover = '';
  dom.Element? scope = h1?.parent;
  for (var i = 0; i < 4 && scope != null && cover.isEmpty; i++) {
    final img = scope.querySelector('img[src]');
    if (img != null) cover = resolveSiteUrl(img.attributes['src']);
    scope = scope.parent;
  }
  if (cover.isEmpty && ld?['image'] is String) {
    cover = resolveSiteUrl(decodeEntities(ld!['image'] as String));
  }
  if (cover.isEmpty) cover = resolveSiteUrl(_meta(doc, 'og:image'));

  // Synopsis: first <p class="text-slate-300 ..."> (episode <a>s share the
  // class, so restrict to <p>).
  var synopsis = _text(doc.querySelector('p.text-slate-300'));
  if (synopsis.isEmpty && ld?['description'] is String) {
    synopsis = decodeEntities(ld!['description'] as String);
  }
  if (synopsis.isEmpty) synopsis = _meta(doc, 'description') ?? '';

  final bodyText = doc.body?.text ?? '';
  final totalMatch = RegExp(
    r'Total:\s*(\d+)\s*Ep',
    caseSensitive: false,
  ).firstMatch(bodyText);
  var total = totalMatch == null ? 0 : int.parse(totalMatch.group(1)!);

  final eps = <int>{};
  for (final a in doc.querySelectorAll('a[href]')) {
    final q = _hrefParams(a.attributes['href']);
    if (q['page'] != 'watch') continue;
    if (q['id'] != null && q['id'] != id) continue;
    final ep = _int(q['ep']);
    if (ep != null && ep > 0) eps.add(ep);
  }
  var episodes = eps.toList()..sort();
  if (total <= 0) total = episodes.isEmpty ? 0 : episodes.last;
  if (episodes.isEmpty && total > 0) {
    episodes = List<int>.generate(total, (i) => i + 1);
  }

  return DramaDetail(
    source: kShortMaxSource,
    id: id,
    title: title,
    cover: cover,
    synopsis: synopsis,
    totalEpisodes: total,
    episodes: episodes,
  );
}

/// Extracts drama cards (`<a href="index.php?page=detail&id=..">`) from a
/// site listing page. Deduped by id, page order preserved.
List<Drama> parseDramaCards(dom.Document doc) {
  final seen = <String>{};
  final out = <Drama>[];
  for (final a in doc.querySelectorAll('a[href]')) {
    final q = _hrefParams(a.attributes['href']);
    if (q['page'] != 'detail') continue;
    final id = q['id']?.trim() ?? '';
    if (id.isEmpty || !seen.add(id)) continue;

    final img = a.querySelector('img');
    var title = _text(a.querySelector('h3'));
    if (title.isEmpty) title = decodeEntities(img?.attributes['alt'] ?? '');
    if (title.isEmpty) title = _text(a);
    if (title.isEmpty) continue;

    int? episodes;
    final m = RegExp(r'Eps?:\s*(\d+)', caseSensitive: false).firstMatch(a.text);
    if (m != null) episodes = int.parse(m.group(1)!);

    out.add(
      Drama(
        source: kShortMaxSource,
        id: id,
        title: title,
        cover: resolveSiteUrl(
          img?.attributes['src'] ?? img?.attributes['data-src'],
        ),
        episodes: episodes,
      ),
    );
  }
  return out;
}

/// Parses `page=search_result&q=&s_page=`.
Paged<Drama> parseSearch(String html, int page) {
  final doc = html_parser.parse(html);
  final items = parseDramaCards(doc);
  var hasMore = false;
  for (final a in doc.querySelectorAll('a[href]')) {
    final q = _hrefParams(a.attributes['href']);
    final isSearchLink = q['page'] == 'search_result';
    if (isSearchLink && _int(q['s_page']) == page + 1) {
      hasMore = true;
      break;
    }
    if (isSearchLink && a.text.toLowerCase().contains('next')) {
      hasMore = true;
      break;
    }
  }
  return Paged(items, hasMore && items.isNotEmpty);
}

/// Parses the site home "Recently Watched" feed (`page=home&p_hist=`).
Paged<Drama> parseRecent(String html, int page) {
  final doc = html_parser.parse(html);
  final items = parseDramaCards(doc);
  var hasMore = false;
  final m = RegExp(
    r'Page\s+(\d+)\s+of\s+(\d+)',
    caseSensitive: false,
  ).firstMatch(doc.body?.text ?? '');
  if (m != null) {
    hasMore = int.parse(m.group(1)!) < int.parse(m.group(2)!);
  } else {
    for (final a in doc.querySelectorAll('a[href]')) {
      final q = _hrefParams(a.attributes['href']);
      if (q.containsKey('p_hist') &&
          (_int(q['p_hist']) == page + 1 ||
              a.text.toLowerCase().contains('next'))) {
        hasMore = true;
        break;
      }
    }
  }
  return Paged(items, hasMore && items.isNotEmpty);
}

int _qualityRank(String label) =>
    int.tryParse(RegExp(r'(\d+)').firstMatch(label)?.group(1) ?? '') ?? 0;

String? _str(Object? v) =>
    (v is String && v.trim().isNotEmpty) ? v.trim() : null;

/// Parses the cdn `action=video_server` JSON body.
EpisodeStream parseEpisodeStream(
  String body,
  String id,
  int ep,
  String server,
) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    throw const ShortMaxException('video_server returned invalid JSON');
  }
  if (decoded is! Map) {
    throw const ShortMaxException('video_server returned unexpected JSON');
  }
  if (decoded['ok'] != true) {
    final msg =
        _str(decoded['message']) ?? _str(decoded['error']) ?? 'ok=false';
    throw ShortMaxException('video_server: $msg');
  }
  final s = decoded['server'];
  if (s is! Map) throw const ShortMaxException('video_server: no server');

  final byLabel = <String, VideoQuality>{};
  final seenUrls = <String>{};
  final qs = s['qualities'];
  if (qs is List) {
    for (final q in qs) {
      if (q is! Map) continue;
      final url = _str(q['playUrl']) ?? _str(q['url']);
      final label = _str(q['quality']) ?? '';
      if (url == null || label.isEmpty) continue;
      if (byLabel.containsKey(label) || !seenUrls.add(url)) continue;
      byLabel[label] = VideoQuality(label, url);
    }
  }
  final qualities = byLabel.values.toList()
    ..sort((a, b) => _qualityRank(b.label).compareTo(_qualityRank(a.label)));

  VideoQuality? pick(String l) {
    for (final q in qualities) {
      if (q.label == l) return q;
    }
    return null;
  }

  final playUrl =
      _str(s['playUrl']) ??
      _str(s['fallbackUrl']) ??
      (pick('720p') ?? (qualities.isEmpty ? null : qualities.first))?.url;
  if (playUrl == null) {
    throw const ShortMaxException('video_server: no playable URL');
  }
  final proxyUrl =
      _str(s['proxyUrl']) ??
      'https://cdn-shortmaxv2.dramafren.org/index.php?action=proxy_video&url='
          '${Uri.encodeComponent(playUrl)}';

  return EpisodeStream(
    dramaId: id,
    ep: ep,
    server: _str(s['key']) ?? server,
    playUrl: playUrl,
    proxyUrl: proxyUrl,
    qualities: qualities,
  );
}

/// A positive integer count (`playNum` is a number, sometimes a string).
int? _count(Object? v) {
  final n = v is num ? v.toInt() : int.tryParse('${v ?? ''}'.trim());
  return (n == null || n <= 0) ? null : n;
}

/// Maps official `cmsShortPlay/queryPage` `data` to a page of dramas.
/// [Drama.views] is the real `playNum` when present.
Paged<Drama> parseOfficialPage(Object? data, int page, int pageSize) {
  if (data is! Map) {
    throw const ShortMaxException('queryPage: unexpected data');
  }
  final list = data['list'];
  final total = data['total'] is num ? (data['total'] as num).toInt() : 0;
  final items = <Drama>[];
  if (list is List) {
    for (final x in list) {
      if (x is! Map) continue;
      final code = x['shortPlayCode'];
      final id = code == null ? '' : code.toString().trim();
      if (id.isEmpty) continue;
      final title =
          _str(x['lanShortPlayName']) ?? _str(x['shortPlayName']) ?? '';
      if (title.isEmpty) continue;
      items.add(
        Drama(
          source: kShortMaxSource,
          id: id,
          title: decodeEntities(title),
          cover: _str(x['lanCoverId']) ?? _str(x['coverId']) ?? '',
          synopsis: _str(x['lanShortPlayDescription']) ?? _str(x['summary']),
          views: _count(x['playNum']),
        ),
      );
    }
  }
  final hasMore = (list is List && list.isNotEmpty) && page * pageSize < total;
  return Paged(items, hasMore);
}

/// Maps official `cmsClassNew/queryList` `data` to categories.
List<Category> parseCategories(Object? data) {
  if (data is! List) {
    throw const ShortMaxException('queryList: unexpected data');
  }
  final seen = <int>{};
  final out = <Category>[];
  for (final x in data) {
    if (x is! Map) continue;
    final idRaw = x['classId'];
    final classId = idRaw is num ? idRaw.toInt() : int.tryParse('$idRaw');
    if (classId == null || !seen.add(classId)) continue;
    final name =
        _str(x['displayName']) ??
        _str(x['rawName']) ??
        _str(x['className']) ??
        '';
    if (name.isEmpty) continue;
    out.add(Category(classId, name));
  }
  return out;
}
