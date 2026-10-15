// OWNER: shelves agent. Home filter chips ("shelves"): definitions, the genre
// classifier and the paging engine the Catalog builds shelves with.
// Pure Dart, no I/O of its own — unit-tested in test/shelves_test.dart.
import 'dart:async';

import '../models.dart';
import 'ranking.dart' show normalizeTitle, richness;

/// Items per shelf page.
const int kShelfPageSize = 30;

// ------------------------------------------------------------- definitions

/// A genre shelf (id `g:<slug>`).
class GenreDef {
  final String slug;
  final String label;

  /// Classifier terms, matched as whole words on title + synopsis (plural
  /// "s"/"es" allowed). A trailing `*` makes the last word a prefix
  /// ("betray*" = betray, betrayal, betrayed). Multi-word = phrase.
  final List<String> terms;

  /// Phrases removed before matching (false friends, e.g. NetShort's
  /// "Wolf in Disguise" tag is not about werewolves).
  final List<String> exclude;

  /// 2-4 strongest queries fanned out to every source's search.
  final List<String> search;

  /// ShortMax official category display names (lowercase) whose items
  /// belong here.
  final List<String> classes;

  const GenreDef(
    this.slug,
    this.label, {
    required this.terms,
    required this.search,
    this.exclude = const [],
    this.classes = const [],
  });

  String get id => 'g:$slug';
}

const List<GenreDef> kGenres = [
  GenreDef(
    'romance',
    'Romance',
    terms: [
      'romance',
      'romantic',
      'love',
      'lover',
      'loved',
      'loving',
      'crush',
      'kiss',
      'sweetheart',
      'fall for',
      'fell for',
      'falling for',
    ],
    search: ['romance', 'love', 'sweet romance'],
    classes: ['romance', 'modern romance', 'historical romance'],
  ),
  GenreDef(
    'billionaire',
    'Billionaire',
    terms: [
      'ceo',
      'billionaire',
      'trillionaire',
      'millionaire',
      'tycoon',
      'heir',
      'heiress',
      'rich',
      'richest',
      'magnate',
      'mogul',
      'rich family',
    ],
    search: ['billionaire', 'ceo', 'heiress', 'tycoon'],
    classes: ['billionaire lifestyle', 'rich family saga'],
  ),
  GenreDef(
    'werewolf',
    'Werewolf',
    terms: [
      'werewolf',
      'werewolves',
      'alpha',
      'wolf',
      'wolves',
      'luna',
      'lycan*',
      'mate',
      'mated',
      'fated mate',
    ],
    exclude: ['wolf in disguise', 'wolf in sheep'],
    search: ['werewolf', 'alpha', 'luna', 'lycan'],
    classes: ['werewolf'],
  ),
  GenreDef(
    'revenge',
    'Revenge',
    terms: [
      'revenge',
      'vengeance',
      'avenge*',
      'payback',
      'karma',
      'betray*',
      'face slap*',
      'get even',
    ],
    search: ['revenge', 'betrayed', 'payback'],
  ),
  GenreDef(
    'mafia',
    'Mafia',
    terms: [
      'mafia',
      'don',
      'mob',
      'mobster',
      'gangster',
      'godfather',
      'cartel',
      'crime lord',
      'underworld',
      'capo',
    ],
    search: ['mafia', 'mob boss', 'gangster'],
    classes: ['mafia romance'],
  ),
  GenreDef(
    'fantasy',
    'Fantasy',
    terms: [
      'fantasy',
      'dragon',
      'magic*',
      'cultivat*',
      'immortal',
      'god',
      'goddess',
      'system',
      'another world',
      'sorcer*',
      'witch',
      'wizard',
      'elf',
      'elves',
      'fairy',
      'fairies',
      'demon',
      'deity',
      'divine',
      'celestial',
      'mermaid',
      'djinn',
      'sect',
    ],
    search: ['dragon', 'magic', 'immortal', 'cultivation'],
    classes: [
      'fantasy',
      'high fantasy',
      'urban fantasy',
      'cultivation fantasy',
      'dragonkin',
    ],
  ),
  GenreDef(
    'vampire',
    'Vampire',
    terms: ['vampir*', 'dracula', 'nosferatu'],
    search: ['vampire', 'dracula'],
    classes: ['vampire'],
  ),
  GenreDef(
    'rebirth',
    'Rebirth',
    terms: [
      'reborn',
      'rebirth',
      'second chance',
      'time travel*',
      'back in time',
      'past life',
      'second life',
      'reincarnat*',
      'transmigrat*',
    ],
    search: ['reborn', 'rebirth', 'second chance', 'time travel'],
    classes: ['time travel to past'],
  ),
  GenreDef(
    'secret_baby',
    'Secret Baby',
    terms: [
      'baby',
      'babies',
      'pregnant',
      'pregnancy',
      'twins',
      'triplets',
      'quadruplets',
      'quintuplets',
      'kid',
      'daddy',
      'daddies',
      'mommy',
      'mommies',
      'secret child',
      'secret son',
      'secret daughter',
    ],
    exclude: ['sugar daddy', 'sugar babies', 'sugar baby'],
    search: ['baby', 'pregnant', 'twins', 'daddy'],
  ),
  GenreDef(
    'marriage',
    'Marriage',
    terms: [
      'contract marriage',
      'marriage',
      'married',
      'marry',
      'marries',
      'wife',
      'wives',
      'husband',
      'bride',
      'groom',
      'divorce*',
      'wedding',
      'spouse',
    ],
    search: ['contract marriage', 'wife', 'bride', 'divorce'],
  ),
  GenreDef(
    'dubbed',
    'Dubbed',
    terms: [
      'dub',
      'dubbed',
      'dubbing',
      'dublado',
      'dublada',
      'doblado',
      'doblada',
      'doblaje',
    ],
    search: ['dubbed', 'dublado', 'doblado'],
  ),
];

const List<Shelf> kFixedShelves = [
  Shelf('for_you', 'For you'),
  Shelf('most_viewed', 'Most viewed'),
  Shelf('trending', 'Trending'),
  Shelf('new', 'New'),
];

/// Every shelf, in chip order. First is 'for_you'.
final List<Shelf> kShelves = List.unmodifiable([
  ...kFixedShelves,
  for (final g in kGenres) Shelf(g.id, g.label),
]);

GenreDef? genreFor(String shelfId) {
  for (final g in kGenres) {
    if (g.id == shelfId) return g;
  }
  return null;
}

// -------------------------------------------------------------- classifier

final RegExp _apos = RegExp(r"['’‘`´]");
final RegExp _nonWordU = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

/// Lowercase, apostrophes dropped ("don't" -> "dont"), everything that is
/// not a letter/digit -> one space. Padded with spaces.
String classifierText(String s) =>
    ' ${s.toLowerCase().replaceAll(_apos, '').replaceAll(_nonWordU, ' ').trim()} ';

final Map<String, (RegExp, List<String>)> _compiled = {};

(RegExp, List<String>) _genreRe(GenreDef g) => _compiled[g.slug] ??= () {
  String alt(String term) {
    final prefix = term.endsWith('*');
    final words = classifierText(
      prefix ? term.substring(0, term.length - 1) : term,
    ).trim().split(' ').map(RegExp.escape).join(' ');
    return prefix ? '$words[\\p{L}\\p{N}]*' : '$words(?:s|es)?';
  }

  final re = RegExp(
    '(?<![\\p{L}\\p{N}])(${g.terms.map(alt).join('|')})(?![\\p{L}\\p{N}])',
    unicode: true,
  );
  return (re, [for (final e in g.exclude) classifierText(e)]);
}();

/// Distinct classifier terms of [g] found in [text] (raw text).
Set<String> genreHits(GenreDef g, String text) {
  if (text.trim().isEmpty) return const {};
  final (re, excl) = _genreRe(g);
  var t = classifierText(text);
  for (final e in excl) {
    t = t.replaceAll(e, ' ');
  }
  return {for (final m in re.allMatches(t)) m.group(1)!};
}

/// How strongly [d] belongs to genre [g]: 0 = not at all. A title hit
/// scores 1.0, a synopsis/tag-only hit 0.6, a bare official-category item
/// ([inCategory]) 0.7; extra distinct terms add a little.
double genreScore(GenreDef g, Drama d, {bool inCategory = false}) {
  final inTitle = genreHits(g, d.title);
  final inSyn = genreHits(g, d.synopsis ?? '');
  if (inTitle.isEmpty && inSyn.isEmpty) return inCategory ? 0.7 : 0;
  final distinct = {...inTitle, ...inSyn}.length;
  var s = inTitle.isNotEmpty ? 1.0 : 0.6;
  s += 0.05 * (distinct - 1).clamp(0, 4);
  if (inCategory) s += 0.1;
  return s;
}

bool matchesGenre(GenreDef g, Drama d) => genreScore(g, d) > 0;

// ------------------------------------------------------------------ engine

/// Delivers one page of a lane: calls [add] with items (any number of
/// times, e.g. per search chunk) and returns whether the lane has more.
typedef LaneFetch =
    Future<bool> Function(int page, void Function(Iterable<Drama>) add);

/// One ordered stream of candidates (a source's history, a provider's
/// newest list, a genre search on one source...).
class ShelfLane {
  ShelfLane({
    required this.name,
    required this.group,
    required this.fetch,
    this.weight = 1,
    this.paged = true,
    this.score,
  });

  final String name;

  /// Registry priority of the source (lower wins dedupe; interleave unit).
  final int group;

  /// Items this group gets per interleave round.
  final int weight;
  final LaneFetch fetch;

  /// Paged lanes fetch more pages as they run low; others fetch once.
  final bool paged;

  /// Per-lane candidate score (0 = drop); overrides the session's.
  final double Function(Drama)? score;

  int nextPage = 1;
  bool exhausted = false;
  int failures = 0;
  bool delivered = false;
  Future<void>? inflight;
  final Set<String> seen = {};
}

enum ShelfOrder {
  /// Weighted round-robin over groups (registry sources), round-robin over
  /// [Drama.source]s inside a group; best score first inside each queue.
  interleave,

  /// By [Drama.views], highest first (items without views are dropped).
  views,
}

class _Cand {
  final Drama d;
  final ShelfLane lane;
  final double score;
  final int seq;
  final String title;
  bool used = false;
  _Cand(this.d, this.lane, this.score, this.seq)
    : title = normalizeTitle(d.title);
}

/// A shelf being paged through. Lanes are started lazily; each page takes
/// the best not-yet-shown items (deduped by key and normalized title) that
/// are available when it is due. Never throws: failing lanes are dropped.
class ShelfSession {
  ShelfSession({
    required this.lanes,
    this.order = ShelfOrder.interleave,
    this.score,
    this.pageSize = kShelfPageSize,
    this.firstWait = const Duration(seconds: 4),
    this.maxWait = const Duration(seconds: 25),
    this.laterGrace = const Duration(milliseconds: 800),
    this.waitAllAfterFirst = false,
    this.viewsTiebreak = false,
    this.lowWater = 12,
    this.onLaneOk,
  });

  final List<ShelfLane> lanes;
  final ShelfOrder order;

  /// Candidate score (0 = drop); null = every item scores 1.
  final double Function(Drama)? score;
  final int pageSize;

  /// Page 1 returns once every lane answered, or after [firstWait] if it
  /// has anything to show (else keeps waiting up to [maxWait]).
  final Duration firstWait;
  final Duration maxWait;

  /// Later pages: once a page's worth is available, how long to wait for
  /// lanes still loading before returning.
  final Duration laterGrace;

  /// Later pages wait for every lane (up to [maxWait]) — for orders where
  /// a late lane changes the ranking (most viewed).
  final bool waitAllAfterFirst;

  /// Inside a queue, equal scores go most-viewed first (else lane order —
  /// which must be kept for history / newest lists).
  final bool viewsTiebreak;

  /// A paged lane with fewer unshown items than this fetches its next page.
  final int lowWater;

  /// Called with a lane after it delivered successfully.
  final void Function(ShelfLane)? onLaneOk;

  final DateTime created = DateTime.now();
  final List<_Cand> _pool = [];
  final Set<String> _shownKeys = {};
  final Set<String> _shownTitles = {};
  final List<Paged<Drama>> _pages = [];
  Future<void> _tail = Future.value();
  Completer<void>? _changed;
  int _seq = 0;

  int get pagesServed => _pages.length;

  /// Page [n] >= 1 (earlier pages are computed first if needed).
  Future<Paged<Drama>> page(int n) {
    final r = _tail.then((_) async {
      final want = n < 1 ? 1 : n;
      while (_pages.length < want) {
        _pages.add(await _next());
      }
      return _pages[want - 1];
    });
    _tail = r.then((_) {}, onError: (_) {});
    return r;
  }

  void _poke() {
    final c = _changed;
    _changed = null;
    c?.complete();
  }

  int _add(ShelfLane l, Iterable<Drama> items) {
    var fresh = 0;
    for (final d in items) {
      if (!l.seen.add(d.key)) continue;
      fresh++;
      final s = (l.score ?? score)?.call(d) ?? 1.0;
      if (s <= 0) continue;
      _pool.add(_Cand(d, l, s, _seq++));
    }
    if (fresh > 0) _poke();
    return fresh;
  }

  void _start(ShelfLane l) {
    if (l.exhausted || l.inflight != null) return;
    final page = l.nextPage;
    var fresh = 0;
    l.inflight =
        () async {
          try {
            final more = await l.fetch(
              page,
              (items) => fresh += _add(l, items),
            );
            l.nextPage++;
            l.failures = 0;
            l.delivered = true;
            onLaneOk?.call(l);
            if (!l.paged || !more || fresh == 0) l.exhausted = true;
          } catch (_) {
            if (!l.paged || ++l.failures >= 2) l.exhausted = true;
          }
        }().whenComplete(() {
          l.inflight = null;
          _poke();
        });
  }

  bool _isShown(_Cand c) =>
      _shownKeys.contains(c.d.key) ||
      (c.title.isNotEmpty && _shownTitles.contains(c.title));

  int _available([ShelfLane? lane]) {
    var n = 0;
    for (final c in _pool) {
      if (c.used || (lane != null && c.lane != lane)) continue;
      if (_isShown(c)) {
        c.used = true;
        continue;
      }
      n++;
    }
    return n;
  }

  bool get _busy => lanes.any((l) => l.inflight != null);

  Future<Paged<Drama>> _next() async {
    final first = _pages.isEmpty;
    for (final l in lanes) {
      if (l.exhausted || l.inflight != null) continue;
      if (l.nextPage == 1 || (l.paged && _available(l) < lowWater)) _start(l);
    }

    final sw = Stopwatch()..start();
    while (_busy && sw.elapsed < maxWait) {
      final e = sw.elapsed;
      final have = _available();
      if (first) {
        if (have > 0 && e >= firstWait) break;
      } else if (!waitAllAfterFirst) {
        if (have >= pageSize && e >= laterGrace) break;
        if (have > 0 && e >= firstWait) break;
      }
      final c = _changed ??= Completer<void>();
      await c.future.timeout(
        const Duration(milliseconds: 200),
        onTimeout: () {},
      );
    }

    final items = _compose();
    final hasMore =
        _available() > 0 ||
        lanes.any((l) => !l.exhausted || l.inflight != null);
    return Paged(items, hasMore);
  }

  bool _better(_Cand a, _Cand b) {
    if (a.lane.group != b.lane.group) return a.lane.group < b.lane.group;
    if (order == ShelfOrder.views && (a.d.views ?? 0) != (b.d.views ?? 0)) {
      return (a.d.views ?? 0) > (b.d.views ?? 0);
    }
    if (a.score != b.score) return a.score > b.score;
    final ra = richness(a.d), rb = richness(b.d);
    if (ra != rb) return ra > rb;
    return a.seq < b.seq;
  }

  int _queueOrder(_Cand a, _Cand b) {
    final s = b.score.compareTo(a.score);
    if (s != 0) return s;
    if (viewsTiebreak) {
      final v = (b.d.views ?? 0).compareTo(a.d.views ?? 0);
      if (v != 0) return v;
    }
    return a.seq.compareTo(b.seq);
  }

  List<Drama> _compose() {
    // Best unshown copy per title.
    final best = <String, _Cand>{};
    for (final c in _pool) {
      if (c.used) continue;
      if (_isShown(c)) {
        c.used = true;
        continue;
      }
      final k = c.title.isEmpty ? c.d.key : c.title;
      final at = best[k];
      if (at == null || _better(c, at)) best[k] = c;
    }
    final cands = best.values.toList();
    final picked = <_Cand>[];

    if (order == ShelfOrder.views) {
      cands.removeWhere((c) => c.d.views == null);
      cands.sort((a, b) {
        final v = b.d.views!.compareTo(a.d.views!);
        return v != 0 ? v : a.seq.compareTo(b.seq);
      });
      picked.addAll(cands.take(pageSize));
    } else {
      // group -> Drama.source -> queue
      final groups = <int, Map<String, List<_Cand>>>{};
      final weights = <int, int>{};
      for (final c in cands) {
        ((groups[c.lane.group] ??= {})[c.d.source] ??= []).add(c);
        final w = c.lane.weight < 1 ? 1 : c.lane.weight;
        if (w > (weights[c.lane.group] ?? 0)) weights[c.lane.group] = w;
      }
      final gs = groups.keys.toList()..sort();
      final queues = <int, List<List<_Cand>>>{};
      final turn = <int, int>{};
      for (final g in gs) {
        final qs = groups[g]!.values.toList();
        for (final q in qs) {
          q.sort(_queueOrder);
        }
        qs.sort((a, b) => _queueOrder(a.first, b.first));
        queues[g] = qs;
        turn[g] = 0;
      }
      _Cand? takeFrom(int g) {
        final qs = queues[g]!;
        for (var tries = 0; tries < qs.length; tries++) {
          final q = qs[turn[g]! % qs.length];
          turn[g] = turn[g]! + 1;
          if (q.isNotEmpty) return q.removeAt(0);
        }
        return null;
      }

      var progress = true;
      while (picked.length < pageSize && progress) {
        progress = false;
        for (final g in gs) {
          for (var k = 0; k < weights[g]! && picked.length < pageSize; k++) {
            final c = takeFrom(g);
            if (c == null) break;
            picked.add(c);
            progress = true;
          }
        }
      }
    }

    for (final c in picked) {
      c.used = true;
      _shownKeys.add(c.d.key);
      if (c.title.isNotEmpty) _shownTitles.add(c.title);
    }
    return [for (final c in picked) c.d];
  }
}
