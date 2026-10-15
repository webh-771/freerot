import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shortmax_player/data/catalog.dart';
import 'package:shortmax_player/data/source.dart';
import 'package:shortmax_player/data/sources/progressive.dart';
import 'package:shortmax_player/data/sources/reelfren_source.dart';
import 'package:shortmax_player/models.dart';

class FakeSource extends DramaSource {
  FakeSource(
    this.key, {
    this.weight = 1,
    this.pages = const {},
    this.results = const [],
    this.delay = Duration.zero,
    this.fail = false,
  });

  @override
  final String key;
  final int weight;
  final Map<int, List<String>> pages; // page -> titles
  final List<String> results;
  final Duration delay;
  final bool fail;
  final List<int> feedCalls = [];

  Drama _d(String t) => Drama(source: key, id: t, title: t, cover: 'c');

  @override
  bool handles(String s) => s == key;
  @override
  String label(String s) => key.toUpperCase();
  @override
  int get feedWeight => weight;

  @override
  Future<Paged<Drama>> feed(int page) async {
    feedCalls.add(page);
    await Future<void>.delayed(delay);
    if (fail) throw SourceException('boom');
    final t = pages[page] ?? const [];
    return Paged([for (final x in t) _d(x)], pages.containsKey(page + 1));
  }

  @override
  Future<List<Drama>> search(String q) async {
    await Future<void>.delayed(delay);
    if (fail) throw SourceException('boom');
    return [for (final x in results) _d(x)];
  }

  @override
  Future<DramaDetail> detail(Drama d) async => DramaDetail(
        source: key, id: d.id, title: d.title, cover: '', synopsis: '',
        totalEpisodes: 1, episodes: const [1]);
  @override
  List<String> servers(DramaDetail d) => ['$key-s1'];
  @override
  Future<EpisodeStream> episode(DramaDetail d, int ep,
          {required String server}) async =>
      EpisodeStream(dramaId: d.id, ep: ep, server: server, playUrl: 'u',
          proxyUrl: '', qualities: const []);
}

class ChunkySource extends FakeSource implements ProgressiveSearch {
  ChunkySource(super.key, this.chunks);
  final List<(int, List<String>)> chunks; // (delay ms, titles)

  @override
  Stream<List<Drama>> searchChunks(String q) async* {
    for (final (ms, titles) in chunks) {
      await Future<void>.delayed(Duration(milliseconds: ms));
      yield [for (final t in titles) Drama(source: key, id: t, title: t, cover: '')];
    }
  }
}

void main() {
  group('feed', () {
    test('weighted interleave + dedupe by key and title', () async {
      final a = FakeSource('a', weight: 1, pages: {
        1: ['A1', 'A2', 'Shared Title'],
      });
      final b = FakeSource('b', weight: 3, pages: {
        1: ['B1', 'B2', 'B3', 'B4', "Shared Title!"],
      });
      final c = Catalog.withSources([a, b]);
      final p = await c.feed(1);
      expect(p.items.map((d) => d.title),
          ['A1', 'B1', 'B2', 'B3', 'A2', 'B4', 'Shared Title!']);
      // First copy wins in the feed; A's "Shared Title" is a duplicate.
      expect(p.items.last.source, 'b');
      expect(p.hasMore, isFalse);
    });

    test('failing source is skipped', () async {
      final a = FakeSource('a', fail: true);
      final b = FakeSource('b', pages: {1: ['B1']});
      final p = await Catalog.withSources([a, b]).feed(1);
      expect(p.items.map((d) => d.title), ['B1']);
    });

    test('slow source does not block the page; lands on a later page',
        () async {
      final slow = FakeSource('slow',
          delay: const Duration(milliseconds: 600), pages: {1: ['S1']});
      final fast = FakeSource('fast', pages: {
        1: ['F1'],
        2: ['F2'],
      });
      final c = Catalog.withSources([slow, fast],
          feedMaxWait: const Duration(seconds: 5),
          feedGrace: const Duration(milliseconds: 100));
      final sw = Stopwatch()..start();
      final p1 = await c.feed(1);
      expect(sw.elapsedMilliseconds, lessThan(500));
      expect(p1.items.map((d) => d.title), ['F1']);
      expect(p1.hasMore, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final p2 = await c.feed(2);
      expect(p2.items.map((d) => d.title), ['S1', 'F2']);
      expect(slow.feedCalls, [1]); // not re-requested
    });

    test('feed(1) resets the session; same page is cached', () async {
      final a = FakeSource('a', pages: {1: ['A1'], 2: ['A2']});
      final c = Catalog.withSources([a]);
      expect((await c.feed(1)).items.single.title, 'A1');
      expect((await c.feed(2)).items.single.title, 'A2');
      expect((await c.feed(2)).items.single.title, 'A2');
      expect((await c.feed(1)).items.single.title, 'A1');
    });

    test('max wait caps a page when nothing arrives', () async {
      final slow = FakeSource('slow',
          delay: const Duration(seconds: 2), pages: {1: ['S1']});
      final c = Catalog.withSources([slow],
          feedMaxWait: const Duration(milliseconds: 150));
      final sw = Stopwatch()..start();
      final p = await c.feed(1);
      expect(sw.elapsedMilliseconds, lessThan(1500));
      expect(p.items, isEmpty);
      expect(p.hasMore, isTrue);
    });
  });

  group('search', () {
    test('emits after each source, ranked + deduped, then closes', () async {
      final fast = FakeSource('fast', results: ['The CEO Returns', 'Unrelated']);
      final slow = FakeSource('slow',
          delay: const Duration(milliseconds: 200),
          results: ['CEO', 'The CEO Returns']);
      final c = Catalog.withSources([slow, fast]);
      final emissions = await c.search('ceo').toList();
      expect(emissions.length, 2);
      expect(emissions[0].map((d) => d.title), ['The CEO Returns']);
      expect(emissions[1].map((d) => d.key), ['slow:CEO', 'slow:The CEO Returns']);
    });

    test('failing + timed-out sources still close the stream', () async {
      final bad = FakeSource('bad', fail: true);
      final hang = FakeSource('hang',
          delay: const Duration(seconds: 5), results: ['CEO']);
      final c = Catalog.withSources([bad, hang],
          searchTimeout: const Duration(milliseconds: 100));
      final emissions = await c.search('ceo').toList();
      expect(emissions, [isEmpty]);
    });

    test('progressive source: chunks coalesced by emit interval', () async {
      final chunky = ChunkySource('rf', [
        (0, ['Love A']),
        (20, ['Love B']), // within the interval -> coalesced
        (20, ['Love C']),
        (300, ['Love D']),
      ]);
      final c = Catalog.withSources([chunky],
          searchEmitInterval: const Duration(milliseconds: 150));
      final emissions = await c.search('love').toList();
      expect(emissions.first.map((d) => d.title), ['Love A']);
      expect(emissions.last.map((d) => d.title),
          ['Love A', 'Love B', 'Love C', 'Love D']);
      expect(emissions.length, inInclusiveRange(3, 4));
    });

    test('progressive source cut off at the search timeout', () async {
      final chunky = ChunkySource('rf', [
        (0, ['Love A']),
        (1000, ['Love B']),
      ]);
      final c = Catalog.withSources([chunky],
          searchTimeout: const Duration(milliseconds: 200));
      final sw = Stopwatch()..start();
      final emissions = await c.search('love').toList();
      expect(sw.elapsedMilliseconds, lessThan(900));
      expect(emissions.last.map((d) => d.title), ['Love A']);
    });

    test('empty query', () async {
      final c = Catalog.withSources([FakeSource('a', results: ['x'])]);
      expect(await c.search('  ').toList(), [isEmpty]);
    });
  });

  group('routing', () {
    test('detail cached, servers/episode/label routed', () async {
      final a = FakeSource('a');
      final b = FakeSource('b');
      final c = Catalog.withSources([a, b]);
      const drama = Drama(source: 'b', id: 'x', title: 'X', cover: '');
      final d1 = c.detail(drama);
      expect(identical(d1, c.detail(drama)), isTrue);
      final d = await d1;
      expect(c.servers(d), ['b-s1']);
      expect((await c.episode(d, 1, server: 'b-s1')).server, 'b-s1');
      expect(c.sourceLabel('a'), 'A');
      expect(c.sourceLabel('zzz'), 'zzz');
      expect(() => c.servers(const DramaDetail(source: 'zzz', id: '', title: '',
          cover: '', synopsis: '', totalEpisodes: 0, episodes: [])),
          throwsA(isA<SourceException>()));
    });
  });

  group('ReelFren feed (mock http)', () {
    Map<String, Object> item(String p, String id) =>
        {'id': id, 'provider': p, 'title': '$p $id', 'cover': 'c', 'episodes': 10};

    test('round-robin providers, dramabox repeat + dump handled', () async {
      final calls = <String>[];
      final client = MockClient((req) async {
        final p = req.url.queryParameters['provider']!;
        final off = int.parse(req.url.queryParameters['offset']!);
        calls.add('$p:$off');
        List<Map<String, Object>> data;
        if (p == 'dramabox') {
          data = [item(p, 'd1'), item(p, 'd2')]; // ignores offset
        } else if (p == 'wetv') {
          data = off == 0 ? [for (var i = 0; i < 45; i++) item(p, 'w$i')] : [];
        } else if (p == 'broken') {
          return http.Response('error code: 502', 502);
        } else {
          data = off < 2 ? [item(p, 'n${off}a'), item(p, 'n${off}b')] : [];
        }
        return http.Response(jsonEncode({'offset': off, 'data': data}), 200);
      });
      final rf = ReelFrenSource(
          client: client,
          providers: ['netshort', 'dramabox', 'wetv', 'broken', 'filmbox']);
      final p1 = await rf.feed(1);
      expect(p1.items.map((d) => d.id),
          ['n0a', 'd1', 'w0', 'n0b', 'd2', 'w1']);
      expect(p1.items.first.source, 'rf:netshort');
      final p2 = await rf.feed(2);
      expect(p2.items.map((d) => d.id), ['n1a', 'w2', 'n1b', 'w3']);
      expect(calls.where((c) => c.startsWith('wetv')), ['wetv:0']);
      expect(calls.where((c) => c.startsWith('filmbox')), isEmpty);
      // Page 1 again: cached HTTP, fresh cursors.
      final again = await rf.feed(1);
      expect(again.items.map((d) => d.id), p1.items.map((d) => d.id));
      expect(calls.where((c) => c == 'netshort:0').length, 1);
    });

    test('search fans out per provider, one chunk each', () async {
      final asked = <String>[];
      final rf = ReelFrenSource(
        providers: ['netshort', 'dramabox', 'broken'],
        client: MockClient((req) async {
          expect(req.url.path, '/api/search');
          final p = req.url.queryParameters['provider']!;
          asked.add(p);
          if (p == 'broken') return http.Response('error code: 502', 502);
          return http.Response(
              jsonEncode({'data': [item(p, '1'), item('filmbox', 'x')]}), 200);
        }),
      );
      final chunks = await rf.searchChunks('love').toList();
      expect(asked.toSet(), {'netshort', 'dramabox', 'broken'});
      expect(chunks.length, 2);
      expect(chunks.expand((c) => c).map((d) => d.source).toSet(),
          {'rf:netshort', 'rf:dramabox'});
      expect((await rf.search('love')).length, 2);
    });

    test('502 on /api/video -> EpisodeLockedException', () async {
      final rf = ReelFrenSource(
          client: MockClient((_) async => http.Response('error code: 502', 502)));
      const d = DramaDetail(source: 'rf:vibeshort', id: '1', title: '',
          cover: '', synopsis: '', totalEpisodes: 1, episodes: [1]);
      await expectLater(rf.episode(d, 1, server: '1'),
          throwsA(isA<EpisodeLockedException>()));
    });

    test('refresh server adds refresh params', () async {
      Uri? seen;
      final rf = ReelFrenSource(client: MockClient((req) async {
        seen = req.url;
        return http.Response(
            jsonEncode({'locked': false, 'videoUrl': 'https://a/b.mp4'}), 200);
      }));
      const d = DramaDetail(source: 'rf:netshort', id: '1', title: '',
          cover: '', synopsis: '', totalEpisodes: 1, episodes: [1]);
      final s = await rf.episode(d, 1, server: 'refresh');
      expect(seen!.queryParameters['refresh'], '1');
      expect(seen!.queryParameters['cv'], 'v21');
      expect(seen!.queryParameters['server'], '1');
      expect(s.isHls, isFalse);
    });
  });
}
