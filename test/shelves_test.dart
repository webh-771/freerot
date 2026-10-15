import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shortmax_player/data/catalog.dart';
import 'package:shortmax_player/data/parsers.dart';
import 'package:shortmax_player/data/shelves.dart';
import 'package:shortmax_player/data/source.dart';
import 'package:shortmax_player/data/sources/reelfren_source.dart';
import 'package:shortmax_player/data/sources/shelf_hooks.dart';
import 'package:shortmax_player/data/web/web_session.dart';
import 'package:shortmax_player/models.dart';

Drama dr(
  String source,
  String title, {
  String? id,
  int? views,
  String? synopsis,
}) => Drama(
  source: source,
  id: id ?? title,
  title: title,
  cover: 'c',
  views: views,
  synopsis: synopsis,
);

/// Minimal source: feed pages + search results (by query), optional delay
/// and failure.
class Src extends DramaSource {
  Src(
    this.key, {
    this.weight = 1,
    this.feedPages = const {},
    this.results = const {},
    this.delay = Duration.zero,
    this.error,
  });

  @override
  final String key;
  final int weight;
  final Map<int, List<Drama>> feedPages;
  final Map<String, List<Drama>> results; // query -> items ('*' = any)
  final Duration delay;
  final Exception? error;
  final List<String> searches = [];
  int calls = 0;

  @override
  bool handles(String s) => s == key || s.startsWith('$key:');
  @override
  String label(String s) => key.toUpperCase();
  @override
  int get feedWeight => weight;

  Future<void> _gate() async {
    calls++;
    await Future<void>.delayed(delay);
    if (error != null) throw error!;
  }

  @override
  Future<Paged<Drama>> feed(int page) async {
    await _gate();
    return Paged(feedPages[page] ?? const [], feedPages.containsKey(page + 1));
  }

  @override
  Future<List<Drama>> search(String q) async {
    searches.add(q);
    await _gate();
    return results[q] ?? results['*'] ?? const [];
  }

  @override
  Future<DramaDetail> detail(Drama d) async => throw UnimplementedError();
  @override
  List<String> servers(DramaDetail d) => const ['s1'];
  @override
  Future<EpisodeStream> episode(
    DramaDetail d,
    int ep, {
    required String server,
  }) async => throw UnimplementedError();
}

class HistSrc extends Src implements HistoryFeed {
  HistSrc(super.key, {required this.history, super.delay, super.error});
  final Map<int, List<Drama>> history;
  final List<int> histCalls = [];

  @override
  Future<Paged<Drama>> recentlyWatched(int page) async {
    histCalls.add(page);
    await _gate();
    return Paged(history[page] ?? const [], history.containsKey(page + 1));
  }
}

class ViewSrc extends Src implements ViewCounts, NewestFeed, CategoryListing {
  ViewSrc(
    super.key, {
    this.quick = const [],
    this.all = const [],
    this.allDelay = Duration.zero,
    this.newestPages = const {},
    this.classes = const {},
    super.results,
  });
  final List<Drama> quick;
  final List<Drama> all;
  final Duration allDelay;
  final Map<int, List<Drama>> newestPages;
  final Map<String, List<Drama>> classes; // class name -> items
  List<Drama>? loaded;

  @override
  Future<List<Drama>> viewedQuick() async => quick;
  @override
  Future<List<Drama>> viewedAll() async {
    await Future<void>.delayed(allDelay);
    return loaded = all;
  }

  @override
  List<Drama>? get viewedCached => loaded;

  @override
  List<String> get newestLanes => const ['official'];
  @override
  Future<Paged<Drama>> newest(String lane, int page) async =>
      Paged(newestPages[page] ?? const [], newestPages.containsKey(page + 1));

  @override
  Future<List<Drama>> categoryItems(bool Function(String) match) async => [
    for (final e in classes.entries)
      if (match(e.key)) ...e.value,
  ];
}

class NewSrc extends Src implements NewestFeed {
  NewSrc(super.key, {required this.lanes, super.weight});
  final Map<String, Map<int, List<Drama>>> lanes;

  @override
  List<String> get newestLanes => lanes.keys.toList();
  @override
  Future<Paged<Drama>> newest(String lane, int page) async {
    final l = lanes[lane]!;
    return Paged(l[page] ?? const [], l.containsKey(page + 1));
  }
}

List<String> titles(Paged<Drama> p) => [for (final d in p.items) d.title];

Catalog cat(List<DramaSource> s) => Catalog.withSources(
  s,
  shelfFirstWait: const Duration(milliseconds: 300),
  shelfMaxWait: const Duration(seconds: 3),
);

GenreDef genre(String slug) => genreFor('g:$slug')!;

void main() {
  group('shelf list', () {
    test('order and ids', () {
      final s = cat([]).shelves;
      expect(s.take(4).map((x) => x.id), [
        'for_you',
        'most_viewed',
        'trending',
        'new',
      ]);
      expect(s.take(4).map((x) => x.label), [
        'For you',
        'Most viewed',
        'Trending',
        'New',
      ]);
      final genres = s.skip(4).toList();
      expect(genres.length, greaterThanOrEqualTo(10));
      expect(genres.every((g) => g.id.startsWith('g:')), isTrue);
      expect(s.map((x) => x.id).toSet().length, s.length);
      for (final id in [
        'g:romance',
        'g:billionaire',
        'g:werewolf',
        'g:revenge',
        'g:mafia',
        'g:fantasy',
        'g:vampire',
        'g:rebirth',
        'g:secret_baby',
        'g:marriage',
        'g:dubbed',
      ]) {
        expect(genreFor(id), isNotNull, reason: id);
      }
    });

    test('for_you is the feed; unknown id is empty', () async {
      final c = cat([
        Src(
          'a',
          feedPages: {
            1: [dr('a', 'A1')],
          },
        ),
      ]);
      expect(titles(await c.shelf('for_you', 1)), ['A1']);
      final u = await c.shelf('nope', 1);
      expect(u.items, isEmpty);
      expect(u.hasMore, isFalse);
    });
  });

  group('classifier', () {
    bool hit(String slug, String title, [String? syn]) =>
        matchesGenre(genre(slug), dr('x', title, synopsis: syn));

    test('werewolf: whole words and plurals, no false friends', () {
      expect(hit('werewolf', 'The Alpha King'), isTrue);
      expect(hit('werewolf', 'Two Alphas and Me'), isTrue);
      expect(hit('werewolf', 'Raised by Wolves'), isTrue);
      expect(hit('werewolf', "The Lycan's Bride"), isTrue);
      expect(hit('werewolf', 'Rejected Mate'), isTrue);
      expect(hit('werewolf', 'Alphabet Soup'), isFalse);
      expect(hit('werewolf', 'My Roommate'), isFalse);
      expect(hit('werewolf', 'Lunatic Love'), isFalse);
      // NetShort tag "Wolf in Disguise" is a trope, not werewolves.
      expect(
        hit(
          'werewolf',
          'Campus Bully Buster',
          'Wolf in Disguise, Multiple Identities, Karma Payback',
        ),
        isFalse,
      );
    });

    test('synopsis / NetShort tag list counts, weaker than title', () {
      final g = genre('revenge');
      final tagged = dr(
        'x',
        'Remorse that Cannot Mend',
        synopsis: 'Tragic Love, Revenge, Karma Payback',
      );
      final titled = dr('x', 'Sweet Revenge');
      expect(genreScore(g, tagged), greaterThan(0));
      expect(genreScore(g, titled), greaterThan(genreScore(g, tagged)));
      expect(genreScore(g, dr('x', 'His Betrayal')), 1.0);
      expect(genreScore(g, dr('x', 'Quiet Life')), 0);
      expect(genreScore(g, dr('x', 'Quiet Life'), inCategory: true), 0.7);
    });

    test('other genres', () {
      expect(hit('billionaire', "The CEO's Secret"), isTrue);
      expect(hit('billionaire', 'Enriched Uranium'), isFalse);
      expect(hit('mafia', "Don't Leave Me"), isFalse);
      expect(hit('mafia', 'The Don and I'), isTrue);
      expect(hit('mafia', 'Married to the Mob'), isTrue);
      expect(hit('fantasy', 'Rise of the Dragons'), isTrue);
      expect(hit('fantasy', 'Magical Girl'), isTrue);
      expect(hit('vampire', 'Vampires Among Us'), isTrue);
      expect(hit('rebirth', 'Reborn as the Heiress'), isTrue);
      expect(hit('rebirth', 'A Second Chance at Love'), isTrue);
      expect(hit('rebirth', 'Time Traveling Queen'), isTrue);
      expect(hit('secret_baby', 'Twins for the Billionaire'), isTrue);
      expect(hit('secret_baby', 'Pregnant and Alone'), isTrue);
      expect(hit('secret_baby', 'My Sugar Daddy'), isFalse);
      expect(hit('marriage', 'Contract Marriage with the CEO'), isTrue);
      expect(hit('marriage', 'Divorced at Last'), isTrue);
      expect(
        hit('dubbed', '[Dubbed] I Redeemed The Doomed Beast Cubs'),
        isTrue,
      );
      expect(hit('dubbed', 'Amor Prohibido (Dublado)'), isTrue);
      expect(hit('dubbed', 'Dubai Nights'), isFalse);
      expect(hit('romance', 'Love in Paris'), isTrue);
      expect(hit('romance', 'Glove Maker'), isFalse);
    });
  });

  group('most_viewed', () {
    test('only real views, sorted desc, paged 30 locally', () async {
      final all = [
        for (var i = 0; i < 40; i++) dr('sm', 'T$i', views: 1000 + i * 10),
        dr('sm', 'NoViews'),
      ];
      final sm = ViewSrc('sm', all: all);
      final other = Src(
        'b',
        feedPages: {
          1: [dr('b', 'B1', views: 999999)],
        },
      );
      final c = cat([sm, other]);
      final p1 = await c.shelf('most_viewed', 1);
      expect(p1.items.length, 30);
      expect(p1.items.first.title, 'T39');
      final views = [for (final d in p1.items) d.views!];
      expect(views, [...views]..sort((a, b) => b.compareTo(a)));
      expect(p1.hasMore, isTrue);
      final p2 = await c.shelf('most_viewed', 2);
      expect(titles(p2), [for (var i = 9; i >= 0; i--) 'T$i']);
      expect(p2.hasMore, isFalse);
      final everything = [...p1.items, ...p2.items];
      expect(everything.any((d) => d.views == null), isFalse);
      expect(everything.any((d) => d.source == 'b'), isFalse);
      // cached for the session
      expect(identical(await c.shelf('most_viewed', 1), p1), isTrue);
    });

    test('page 1 uses the quick list while the catalogue loads', () async {
      final sm = ViewSrc(
        'sm',
        quick: [dr('sm', 'Q1', views: 50), dr('sm', 'Q2', views: 70)],
        all: [dr('sm', 'Big', views: 9000), dr('sm', 'Q1', views: 50)],
        allDelay: const Duration(milliseconds: 800),
      );
      final c = cat([sm]);
      final sw = Stopwatch()..start();
      final p1 = await c.shelf('most_viewed', 1);
      expect(sw.elapsedMilliseconds, lessThan(700));
      expect(titles(p1), ['Q2', 'Q1']);
      expect(p1.hasMore, isTrue);
      final p2 = await c.shelf('most_viewed', 2);
      expect(titles(p2), ['Big']); // late catalogue, nothing repeated
    });
  });

  group('trending', () {
    test('round-robin, dedupe by title, registry priority wins', () async {
      final a = HistSrc(
        'a',
        history: {
          1: [dr('a', 'A1'), dr('a', 'Shared Show'), dr('a', 'A3')],
        },
      );
      final b = HistSrc(
        'b',
        history: {
          1: [dr('b', "Shared Show!"), dr('b', 'B2'), dr('b', 'B3')],
        },
      );
      final plain = Src(
        'p',
        feedPages: {
          1: [dr('p', 'P1')],
        },
      );
      final p = await cat([a, b, plain]).shelf('trending', 1);
      // b's copy of the shared title loses to a's (registry priority).
      expect(titles(p), ['A1', 'B2', 'Shared Show', 'B3', 'A3']);
      expect(
        p.items.where((d) => d.title.startsWith('Shared')).single.source,
        'a',
      );
    });

    test('interleaves sources 1:1', () async {
      final a = HistSrc(
        'a',
        history: {
          1: [for (var i = 0; i < 5; i++) dr('a', 'A$i')],
        },
      );
      final b = HistSrc(
        'b',
        history: {
          1: [for (var i = 0; i < 5; i++) dr('b', 'B$i')],
        },
      );
      final p = await cat([a, b]).shelf('trending', 1);
      expect(titles(p).take(6), ['A0', 'B0', 'A1', 'B1', 'A2', 'B2']);
    });

    test('failing and unverified sources are skipped', () async {
      final bad = HistSrc(
        'bad',
        history: const {},
        error: SourceException('x'),
      );
      final cf = HistSrc(
        'cf',
        history: const {},
        error: NeedsVerificationException('https://cf'),
      );
      final ok = HistSrc(
        'ok',
        history: {
          1: [dr('ok', 'OK1')],
        },
      );
      final p = await cat([bad, cf, ok]).shelf('trending', 1);
      expect(titles(p), ['OK1']);
    });

    test('session-gated source only used once it served something', () async {
      final gated = _Gated(
        'g',
        history: {
          1: [dr('g', 'G1')],
        },
        feed: {
          1: [dr('g', 'GF')],
        },
      );
      final ok = HistSrc(
        'ok',
        history: {
          1: [dr('ok', 'OK1')],
        },
      );
      final c = cat([gated, ok]);
      expect(titles(await c.shelf('trending', 1)), ['OK1']);
      expect(gated.histCalls, isEmpty);
      final c2 = cat([gated, ok]);
      await c2.feed(1); // the gated source served the feed -> verified
      expect(titles(await c2.shelf('trending', 1)), ['G1', 'OK1']);
    });

    test('pages continue through history pages', () async {
      final a = HistSrc(
        'a',
        history: {
          1: [for (var i = 0; i < 20; i++) dr('a', 'A$i')],
          2: [for (var i = 20; i < 40; i++) dr('a', 'A$i')],
        },
      );
      final c = cat([a]);
      final p1 = await c.shelf('trending', 1);
      expect(p1.items.length, 20);
      expect(p1.hasMore, isTrue);
      final p2 = await c.shelf('trending', 2);
      expect(p2.items.first.title, 'A20');
      expect(a.histCalls, [1, 2]);
    });
  });

  group('new', () {
    test('interleaves newest lanes, weighted by source', () async {
      final sm = ViewSrc(
        'sm',
        newestPages: {
          1: [dr('sm', 'S1'), dr('sm', 'S2')],
        },
      );
      final rf = NewSrc(
        'rf',
        weight: 2,
        lanes: {
          'x': {
            1: [dr('rf:x', 'X1'), dr('rf:x', 'X2')],
          },
          'y': {
            1: [dr('rf:y', 'Y1'), dr('rf:y', 'Y2')],
          },
        },
      );
      final p = await cat([sm, rf]).shelf('new', 1);
      expect(titles(p), ['S1', 'X1', 'Y1', 'S2', 'X2', 'Y2']);
    });
  });

  group('new (order)', () {
    test('keeps each lane\'s own (newest-first) order despite views', () async {
      final sm = ViewSrc(
        'sm',
        newestPages: {
          1: [
            dr('sm', 'Newest', views: 10),
            dr('sm', 'Middle', views: 5000),
            dr('sm', 'Oldest', views: 900000),
          ],
        },
      );
      final p = await cat([sm]).shelf('new', 1);
      expect(titles(p), ['Newest', 'Middle', 'Oldest']);
    });
  });

  group('genre', () {
    test('search fan-out filtered by classifier, mixed, deduped', () async {
      final sm = ViewSrc(
        'sm',
        results: {
          'werewolf': [dr('sm', 'Werewolf Queen'), dr('sm', 'Office Life')],
          'alpha': [dr('sm', 'Alphabet Girl'), dr('sm', 'The Alpha Returns')],
        },
        classes: {
          'Werewolf': [dr('sm', 'Moonlit Pack', id: 'm1', views: 5)],
          'Modern Romance': [dr('sm', 'Unrelated Love')],
        },
      );
      final rf = Src(
        'rf',
        weight: 1,
        results: {
          '*': [
            dr('rf:net', 'Alpha Returns', synopsis: 'Werewolf, Revenge'),
            dr('rf:net', 'The Alpha Returns'), // dup of sm copy
            dr('rf:net', 'Plain Drama', synopsis: 'Sweet Romance'),
            dr('rf:box', 'Luna Rising'),
          ],
        },
      );
      final c = cat([sm, rf]);
      final p = await c.shelf('g:werewolf', 1);
      final t = titles(p);
      expect(t.toSet(), {
        'Werewolf Queen',
        'The Alpha Returns',
        'Moonlit Pack',
        'Alpha Returns',
        'Luna Rising',
      });
      expect(t.length, t.toSet().length);
      // registry priority wins the duplicate
      expect(
        p.items.firstWhere((d) => d.title == 'The Alpha Returns').source,
        'sm',
      );
      // mixed: rf appears within the first two
      expect(p.items.take(2).map((d) => d.source.split(':').first).toSet(), {
        'sm',
        'rf',
      });
      expect(sm.searches.toSet(), genre('werewolf').search.toSet());
    });

    test('failing / unverified sources skipped, never throws', () async {
      final bad = Src('bad', error: SourceException('x'));
      final cf = Src('cf', error: NeedsVerificationException('https://cf'));
      final ok = Src(
        'ok',
        results: {
          '*': [dr('ok', 'Mafia Bride')],
        },
      );
      final p = await cat([bad, cf, ok]).shelf('g:mafia', 1);
      expect(titles(p), ['Mafia Bride']);
    });

    test(
      'all sources failing gives an empty page, retried next time',
      () async {
        final bad = Src('bad', error: SourceException('x'));
        final c = cat([bad]);
        final p = await c.shelf('g:vampire', 1);
        expect(p.items, isEmpty);
        expect(p.hasMore, isFalse);
        final before = bad.calls;
        await c.shelf('g:vampire', 1);
        expect(bad.calls, greaterThan(before));
      },
    );
  });

  group('source hooks', () {
    test('official page carries playNum as views', () {
      final p = parseOfficialPage(
        {
          'total': 3,
          'list': [
            {'shortPlayCode': '1', 'shortPlayName': 'A', 'playNum': 113364},
            {'shortPlayCode': '2', 'shortPlayName': 'B', 'playNum': '42'},
            {'shortPlayCode': '3', 'shortPlayName': 'C'},
          ],
        },
        1,
        24,
      );
      expect([for (final d in p.items) d.views], [113364, 42, null]);
    });

    test('ReelFren newest lanes: netshort sorted by snowflake id desc; '
        'category passed', () async {
      final seen = <Uri>[];
      final client = MockClient((req) async {
        seen.add(req.url);
        final p = req.url.queryParameters['provider'];
        final data = p == 'netshort'
            ? [
                {
                  'id': '2102241622744113154',
                  'provider': 'netshort',
                  'title': 'Old',
                  'cover': '',
                },
                {
                  'id': '2102294844343181313',
                  'provider': 'netshort',
                  'title': 'Newest',
                  'cover': '',
                },
                {
                  'id': '999',
                  'provider': 'netshort',
                  'title': 'Ancient',
                  'cover': '',
                },
              ]
            : [
                {'id': 'a', 'provider': p, 'title': 'F', 'cover': ''},
              ];
        return http.Response(
          jsonEncode({'data': data}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final rf = ReelFrenSource(client: client);
      expect(rf.newestLanes, ['netshort', 'flextv', 'shorten']);
      final n = await rf.newest('netshort', 1);
      expect(titles(n), ['Newest', 'Old', 'Ancient']);
      await rf.newest('shorten', 2);
      final q = seen.last.queryParameters;
      expect(q['category'], 'releases');
      expect(q['offset'], '1');
      expect(seen.first.queryParameters.containsKey('category'), isFalse);
      expect(compareNumericIds('10', '9'), greaterThan(0));
    });
  });
}

class _Gated extends HistSrc implements SessionGated {
  _Gated(super.key, {required super.history, Map<int, List<Drama>>? feed})
    : _feed = feed ?? const {};
  final Map<int, List<Drama>> _feed;
  @override
  Future<Paged<Drama>> feed(int page) async =>
      Paged(_feed[page] ?? const [], false);
}
