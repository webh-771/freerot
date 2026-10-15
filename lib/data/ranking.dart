// OWNER: catalog agent. Pure title matching / ranking / dedupe helpers used by
// the Catalog for unified search and the mixed feed. No I/O — unit-tested in
// test/ranking_test.dart.
import '../models.dart';

// ------------------------------------------------------------ normalization

const Map<String, String> _fold = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'ā': 'a',
  'ă': 'a', 'ą': 'a', 'æ': 'ae', 'ç': 'c', 'ć': 'c', 'č': 'c', 'ď': 'd',
  'đ': 'd', 'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e', 'ė': 'e',
  'ę': 'e', 'ě': 'e', 'ğ': 'g', 'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i',
  'ī': 'i', 'į': 'i', 'ı': 'i', 'ł': 'l', 'ñ': 'n', 'ń': 'n', 'ň': 'n',
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o', 'ō': 'o',
  'ő': 'o', 'œ': 'oe', 'ř': 'r', 'ś': 's', 'š': 's', 'ş': 's', 'ș': 's',
  'ß': 'ss', 'ť': 't', 'ț': 't', 'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u',
  'ū': 'u', 'ů': 'u', 'ű': 'u', 'ý': 'y', 'ÿ': 'y', 'ź': 'z', 'ż': 'z',
  'ž': 'z', 'þ': 'th', 'ð': 'd',
};

/// Language / release tags that don't identify the show.
const String _tagWords =
    r'dub|dubbed|sub|subs|subbed|subtitled|subtitles|eng|english|hindi|'
    r'spanish|espanol|portuguese|indonesian|korean|chinese|mandarin|'
    r'japanese|thai|arabic|french|german|full|full version|full episodes?|'
    r'uncut|hd|4k|remastered|version|ver';

final RegExp _bracketed = RegExp(r'[\[\(【（「『<]([^\]\)】）」』>]*)[\]\)】）」』>]');
final RegExp _bracketTag = RegExp('^\\s*(?:(?:$_tagWords)[\\s.\\-/,&+]*)+\$');
final RegExp _looseTag = RegExp(
  r'\b(?:(?:eng|english|hindi|spanish)\s+(?:dub|dubbed|sub|subbed|subtitles?)|dubbed|eng dub)\b',
);
final RegExp _possessive = RegExp(r"['’‘`´]s\b");
final RegExp _apostrophe = RegExp(r"['’‘`´]");
final RegExp _nonWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
final RegExp _spaces = RegExp(r'\s+');
final RegExp _letter = RegExp(r'\p{L}', unicode: true);

/// Lowercase, strip diacritics, drop possessive `'s`, drop dub/sub tags such
/// as "[Dubbed]" / "(Eng Dub)" / "english dubbed", turn punctuation into
/// spaces and collapse whitespace. For matching only — never display it.
String normalizeTitle(String title) {
  var s = title.toLowerCase();
  if (s.runes.any((r) => r > 0x7f)) {
    final b = StringBuffer();
    for (final r in s.runes) {
      final ch = String.fromCharCode(r);
      b.write(_fold[ch] ?? ch);
    }
    s = b.toString();
  }
  s = s.replaceAllMapped(
    _bracketed,
    (m) => _bracketTag.hasMatch(m.group(1)!) ? ' ' : ' ${m.group(1)} ',
  );
  s = s.replaceAll(_looseTag, ' ');
  s = s.replaceAll(_possessive, '').replaceAll(_apostrophe, '');
  s = s.replaceAll(_nonWord, ' ').replaceAll(_spaces, ' ').trim();
  return s;
}

const Set<String> _stopWords = {
  'a', 'an', 'the', 'of', 'to', 'in', 'on', 'and', 'or', 'for', 'is', 'my',
  'me', 'i', 'you', 'your', 'his', 'her', 'with', 'at', 'by', 'from', 'be',
};

List<String> _tokens(String normalized) =>
    normalized.isEmpty ? const [] : normalized.split(' ');

bool _isAscii(String s) => s.runes.every((r) => r < 0x80);

/// Fraction of letters in [s] that are ASCII (1.0 for letter-free strings).
double asciiRatio(String s) {
  var letters = 0, ascii = 0;
  for (final m in _letter.allMatches(s)) {
    letters++;
    if (m.group(0)!.codeUnitAt(0) < 0x80) ascii++;
  }
  return letters == 0 ? 1 : ascii / letters;
}

// ------------------------------------------------------------------ scoring

/// Title relevance for [query] in 0..1 (0 = no match). Tiers:
/// exact (1.0) > prefix (0.9) > every query word present as a whole word
/// (0.6–0.85, more for in-order phrase and shorter titles) > raw substring
/// (0.45–0.55) > partial word overlap (0.1 + 0.4 × matched fraction).
double score(String query, String title) {
  final q = normalizeTitle(query);
  final t = normalizeTitle(title);
  if (q.isEmpty || t.isEmpty) return 0;
  if (t == q) return 1.0;
  if (t.startsWith('$q ')) return 0.9;

  final qt = _tokens(q);
  final tt = _tokens(t);
  final significant = qt.where((w) => !_stopWords.contains(w)).toList();
  final need = significant.isEmpty ? qt : significant;
  final titleWords = tt.toSet();
  final coverage = (qt.length / tt.length).clamp(0.0, 1.0);

  // Whole-word hits (plural forms count); a word that is only the start of
  // a title word ("alpha" in "alphabet") is half a hit.
  var hits = 0.0;
  for (final w in need) {
    if (titleWords.contains(w) ||
        titleWords.contains('${w}s') ||
        titleWords.contains('${w}es') ||
        (w.length > 3 && w.endsWith('s') &&
            titleWords.contains(w.substring(0, w.length - 1)))) {
      hits += 1;
    } else if (w.length >= 3 && tt.any((x) => x.startsWith(w))) {
      hits += 0.5;
    }
  }
  final phrase = ' $t '.contains(' $q ');
  if (hits >= need.length) {
    return (phrase ? 0.75 : 0.6) + (phrase ? 0.1 : 0.2) * coverage;
  }
  if (t.contains(q)) return 0.45 + 0.1 * coverage;
  // Partial overlap: kept (>= kMinScore) when about half the significant
  // words match, always below the substring tier.
  final frac = hits / need.length;
  return frac <= 0 ? 0 : 0.1 + 0.4 * frac;
}

/// Matches scoring below this are dropped from search results.
const double kMinScore = 0.25;

/// [score] plus small tie-breaking boosts: known episode count, and an
/// English(ASCII) title when the query is ASCII.
double rankScore(String query, Drama d) {
  final base = score(query, d.title);
  if (base <= 0) return 0;
  var s = base;
  if ((d.episodes ?? 0) > 0) s += 0.02;
  if (_isAscii(query)) {
    final r = asciiRatio(d.title);
    if (r >= 0.9) {
      s += 0.04;
    } else if (r < 0.5) {
      s -= 0.12;
    }
  }
  return s;
}

/// How complete a list entry is (used to pick between duplicate copies).
int richness(Drama d) {
  var r = 0;
  if ((d.episodes ?? 0) > 0) r += 2;
  final syn = d.synopsis?.trim() ?? '';
  if (syn.isNotEmpty && !isPlaceholderIntro(syn)) r += 1;
  if (d.cover.isNotEmpty) r += 1;
  return r;
}

final RegExp _placeholderIntro = RegExp(
  r'^[\w .+-]{1,30}\s(drama|search result|series|short drama)$',
  caseSensitive: false,
);

/// ReelFren's generic intros: "NetShort drama", "Anamana search result".
bool isPlaceholderIntro(String intro) =>
    _placeholderIntro.hasMatch(intro.trim());

// ------------------------------------------------------------- dedupe/rank

/// True if [a] should be kept over [b] for the same normalized title.
/// Lower [priority] wins (registry order), then [richness].
bool _better(Drama a, Drama b, int Function(Drama) priority) {
  final pa = priority(a), pb = priority(b);
  if (pa != pb) return pa < pb;
  return richness(a) > richness(b);
}

/// Dedupe by [Drama.key] and normalized title, keeping the best copy per
/// title (see [_better]). First-seen order of titles is preserved.
List<Drama> dedupe(Iterable<Drama> items, {required int Function(Drama) priority}) {
  final byTitle = <String, int>{};
  final keys = <String>{};
  final out = <Drama>[];
  for (final d in items) {
    if (!keys.add(d.key)) continue;
    final nt = normalizeTitle(d.title);
    final k = nt.isEmpty ? d.key : nt;
    final at = byTitle[k];
    if (at == null) {
      byTitle[k] = out.length;
      out.add(d);
    } else if (_better(d, out[at], priority)) {
      out[at] = d;
    }
  }
  return out;
}

/// Width of a relevance band: results whose [rankScore]s fall in the same
/// band count as equally good and get interleaved across sources.
const double kBandWidth = 0.05;

/// Unified search ranking: dedupe (see [dedupe] — the only place [priority]
/// matters), score every title against [query], drop matches below
/// [minScore], then order best band first. Inside a band, registry sources
/// (grouped by [priority]) are interleaved round-robin so no source owns the
/// top of the list; inside a registry source, its [Drama.source]s (ReelFren
/// providers) are interleaved the same way. Each queue runs best score,
/// then richest, first.
/// Deterministic; at most [limit] results.
List<Drama> rankResults(
  String query,
  Iterable<Drama> items, {
  required int Function(Drama) priority,
  double minScore = kMinScore,
  int limit = 300,
}) {
  final unique = dedupe(items, priority: priority);
  final scored = <(Drama, double, int, int)>[]; // drama, rank, rich, index
  for (var i = 0; i < unique.length; i++) {
    final d = unique[i];
    if (score(query, d.title) < minScore) continue;
    scored.add((d, rankScore(query, d), richness(d), i));
  }
  // Best first within the whole list; ties -> richer, then input order.
  scored.sort((a, b) {
    final c = b.$2.compareTo(a.$2);
    if (c != 0) return c;
    final r = b.$3.compareTo(a.$3);
    if (r != 0) return r;
    return a.$4.compareTo(b.$4);
  });

  final out = <Drama>[];
  var i = 0;
  while (i < scored.length && out.length < limit) {
    // One band (sorted, so a contiguous run), grouped by registry source,
    // then by Drama.source inside it (ReelFren providers). Insertion order
    // = order of each group's best entry.
    final band = (scored[i].$2 / kBandWidth).floor();
    final groups = <int, Map<String, List<Drama>>>{};
    while (i < scored.length && (scored[i].$2 / kBandWidth).floor() == band) {
      final d = scored[i].$1;
      ((groups[priority(d)] ??= {})[d.source] ??= []).add(d);
      i++;
    }
    final queues = [
      for (final g in groups.values) _roundRobin(g.values.toList()),
    ];
    for (final d in _roundRobin(queues)) {
      if (out.length >= limit) break;
      out.add(d);
    }
  }
  return out;
}

List<Drama> _roundRobin(List<List<Drama>> queues) {
  final out = <Drama>[];
  for (var round = 0;; round++) {
    var any = false;
    for (final q in queues) {
      if (round < q.length) {
        out.add(q[round]);
        any = true;
      }
    }
    if (!any) return out;
  }
}
