// OWNER: web-session agent. Pure parsers for the dramafren PHP "player"
// template (idrama, stardusttv, starshort, dramabite, ...). No network code,
// so everything here is unit-tested against probes/fixtures
// (test/php_template_test.dart). Spec: probes/template_dramafren_php.md.
import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../../models.dart';

/// A card from a feed / search page.
class TemplateCard {
  final String id;

  /// stardusttv only: kebab-case title, needed for detail/watch URLs.
  final String? slug;
  final String title;

  /// '' when the page only has a placeholder.
  final String cover;
  final int? episodes;

  const TemplateCard({
    required this.id,
    required this.title,
    required this.cover,
    this.slug,
    this.episodes,
  });
}

/// Parsed detail page.
class TemplateDetail {
  final String title;
  final String cover;
  final String synopsis;
  final int total;
  final List<int> episodes;

  const TemplateDetail({
    required this.title,
    required this.cover,
    required this.synopsis,
    required this.total,
    required this.episodes,
  });
}

/// Collapses whitespace and trims.
String cleanText(String? s) =>
    (s ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();

/// '' for the template's placeholder images (`placehold.co`, "No Cover").
String realCover(String? url) {
  final u = (url ?? '').trim();
  if (u.isEmpty || u.contains('placehold.co') || u.contains('No+Cover')) {
    return '';
  }
  if (u.startsWith('//')) return 'https:$u';
  return u;
}

/// Query parameters of an href (relative `index.php?...` is fine). The html
/// parser already decodes `&amp;`.
Map<String, String> hrefParams(String? href) {
  if (href == null || href.trim().isEmpty) return const {};
  try {
    return Uri.parse('https://x/').resolve(href.trim()).queryParameters;
  } catch (_) {
    return const {};
  }
}

/// `html` from [marker] onwards (whole page if the marker is missing).
String sliceFrom(String html, String? marker) {
  if (marker == null) return html;
  final i = html.indexOf(marker);
  return i >= 0 ? html.substring(i) : html;
}

/// Cards: `a[href*="page=detail"]` with an `img` and an `h3`. Duplicate ids
/// are dropped. Feeds pass `after: 'Recently Watched'`.
List<TemplateCard> parseTemplateCards(String html, {String? after}) {
  final doc = html_parser.parse(sliceFrom(html, after));
  final seen = <String>{};
  final out = <TemplateCard>[];
  for (final a in doc.querySelectorAll('a[href*="page=detail"]')) {
    final q = hrefParams(a.attributes['href']);
    final id = q['id'] ?? '';
    if (id.isEmpty || !seen.add(id)) continue;
    final img = a.querySelector('img');
    var title = cleanText(a.querySelector('h3')?.text);
    if (title.isEmpty) title = cleanText(img?.attributes['alt']);
    if (title.isEmpty || title.toLowerCase() == 'cover') continue;
    final eps = RegExp(r'(\d+)\s*Eps', caseSensitive: false).firstMatch(a.text);
    final slug = q['slug'];
    out.add(TemplateCard(
      id: id,
      slug: (slug == null || slug.isEmpty) ? null : slug,
      title: title,
      cover: realCover(img?.attributes['src']),
      episodes: eps == null ? null : int.tryParse(eps.group(1)!),
    ));
  }
  return out;
}

/// True if the page has a `Next »` link whose [param] is `page + 1`
/// (`hp`, `p_hist`, `p`, `s_page`).
bool templateHasNext(String html, String param, int page) {
  final doc = html_parser.parse(html);
  final want = '${page + 1}';
  for (final a in doc.querySelectorAll('a[href]')) {
    if (!a.text.contains('Next')) continue;
    if (hrefParams(a.attributes['href'])[param] == want) return true;
  }
  return false;
}

/// `(current, total)` from "Page 1 of 9" (also `Page <span>1</span> of 25`).
(int, int)? templatePageOf(String html) {
  final m = RegExp(
    r'Page\s*(?:<[^>]+>\s*)?(\d+)\s*(?:<[^>]+>\s*)?of\s*(?:<[^>]+>\s*)?(\d+)',
  ).firstMatch(html);
  if (m == null) return null;
  return (int.parse(m.group(1)!), int.parse(m.group(2)!));
}

/// Detail page: `<h1>` title, poster `<img>` before the h1 (or `og:image`),
/// `Total: N Eps` / `N Episodes`, first `<p>` after the h1, and every
/// `a[href*="page=watch"]` episode link.
TemplateDetail parseTemplateDetail(String html) {
  final doc = html_parser.parse(html);
  final h1 = doc.querySelector('h1');
  if (h1 == null) throw const FormatException('detail page has no <h1>');
  final title = cleanText(h1.text);

  // Cover: the last <img> before the h1 is the poster; og:image as fallback.
  var cover = '';
  final h1At = html.indexOf('<h1');
  if (h1At > 0) {
    final imgs = RegExp(r'<img[^>]*\ssrc="([^"]+)"')
        .allMatches(html.substring(0, h1At))
        .toList();
    if (imgs.isNotEmpty) {
      cover = realCover(_unescapeAttr(imgs.last.group(1)!));
    }
  }
  if (cover.isEmpty) {
    cover = realCover(
      doc.querySelector('meta[property="og:image"]')?.attributes['content'],
    );
  }

  final box = h1.parent;
  var synopsis = cleanText(box?.querySelector('p')?.text);
  if (synopsis.isEmpty || synopsis == 'Full episodes available.') {
    synopsis = _jsonLdDescription(doc);
  }
  if (synopsis == 'Full episodes available.') synopsis = '';

  final scope = box?.text ?? doc.body?.text ?? '';
  final tm = RegExp(r'Total:\s*(\d+)\s*Eps', caseSensitive: false)
          .firstMatch(scope) ??
      RegExp(r'(\d+)\s*Episodes', caseSensitive: false).firstMatch(scope);
  var total = tm == null ? 0 : int.parse(tm.group(1)!);

  final eps = <int>{};
  for (final a in doc.querySelectorAll('a[href*="page=watch"]')) {
    final ep = int.tryParse(hrefParams(a.attributes['href'])['ep'] ?? '');
    if (ep != null && ep > 0) eps.add(ep);
  }
  var episodes = eps.toList()..sort();
  if (episodes.isNotEmpty && episodes.last > total) total = episodes.last;
  if (episodes.isEmpty && total > 0) {
    episodes = List<int>.generate(total, (i) => i + 1);
  }
  return TemplateDetail(
    title: title,
    cover: cover,
    synopsis: synopsis,
    total: total,
    episodes: episodes,
  );
}

String _unescapeAttr(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#039;', "'");

String _jsonLdDescription(dom.Document doc) {
  for (final s in doc.querySelectorAll('script[type="application/ld+json"]')) {
    try {
      final j = jsonDecode(s.text);
      if (j is Map && j['description'] is String) {
        return cleanText(html_parser.parseFragment(j['description']).text);
      }
    } catch (_) {}
  }
  return '';
}

/// Base64 (standard or URL-safe, padding optional) -> UTF-8 string, or null.
String? decodeB64(String? s) {
  var v = (s ?? '').replaceAll(RegExp(r'\s+'), '');
  if (v.isEmpty) return null;
  v = v.replaceAll('-', '+').replaceAll('_', '/');
  while (v.length % 4 != 0) {
    v += '=';
  }
  try {
    final out = utf8.decode(base64.decode(v), allowMalformed: true).trim();
    return out.isEmpty ? null : out;
  } catch (_) {
    return null;
  }
}

/// `const encryptedSrc = "<b64>"` (stardusttv, starshort).
String? encryptedSrcOf(String html) {
  final m = RegExp(r'''encryptedSrc\s*=\s*["']([^"']*)["']''').firstMatch(html);
  return decodeB64(m?.group(1));
}

/// `const videoSrc = atob("<b64>")` (dramabite, reelshort).
String? atobVideoSrcOf(String html) {
  final m = RegExp(r'''videoSrc\s*=\s*atob\(\s*["']([^"']*)["']\s*\)''')
      .firstMatch(html);
  return decodeB64(m?.group(1));
}

/// `const availableQualities = [...]`: items carry `url` (starshort) or a
/// base64 `hash64` (reelshort).
List<VideoQuality> availableQualitiesOf(String html) {
  final m = RegExp(r'availableQualities\s*=\s*(\[.*?\])\s*;', dotAll: true)
      .firstMatch(html);
  if (m == null) return const [];
  try {
    final list = jsonDecode(m.group(1)!);
    if (list is! List) return const [];
    final out = <VideoQuality>[];
    for (final q in list) {
      if (q is! Map) continue;
      final url = (q['url'] is String && (q['url'] as String).isNotEmpty)
          ? q['url'] as String
          : decodeB64(q['hash64'] as String?);
      if (url == null || url.isEmpty) continue;
      final label = cleanText('${q['quality'] ?? q['label'] ?? 'Auto'}');
      out.add(VideoQuality(label, url, isHls: !url.contains('.mp4')));
    }
    return out;
  } catch (_) {
    return const [];
  }
}

/// The episode's stream URL from a watch page: encryptedSrc, then
/// atob(videoSrc), then the first available quality. null if the page has
/// none (the mirror sometimes renders an empty src).
String? watchVideoUrlOf(String html) {
  final a = encryptedSrcOf(html);
  if (a != null && a.startsWith('http')) return a;
  final b = atobVideoSrcOf(html);
  if (b != null && b.startsWith('http')) return b;
  final q = availableQualitiesOf(html);
  return q.isEmpty ? null : q.first.url;
}

/// Expiry (unix seconds) of an Aliyun type-A `auth_key=<exp>-0-0-<md5>`.
int? authKeyExpiry(String url) {
  final m = RegExp(r'auth_key=(\d+)-').firstMatch(url);
  return m == null ? null : int.tryParse(m.group(1)!);
}
