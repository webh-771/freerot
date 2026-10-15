// GoodShort + FlickReels (CF-free cdn-* twins of the dramafren "Unlocked"
// template). Fixture-based parser/source tests always run; the live group is
// skipped unless LIVE=1:
//   LIVE=1 flutter test test/goodshort_flickreels_test.dart
//
// Like web_idrama_live_test.dart: no Flutter test binding is initialised and
// HttpOverrides are reset, so the live group hits the real network.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shortmax_player/data/source.dart';
import 'package:shortmax_player/data/sources/flickreels_source.dart';
import 'package:shortmax_player/data/sources/goodshort_source.dart';
import 'package:shortmax_player/models.dart';

String fx(String name) => File('probes/fixtures/$name').readAsStringSync();

final bool _live = Platform.environment['LIVE'] == '1';

/// MockClient that answers by `page` / `action` query param and logs URLs.
MockClient fakeClient(Map<String, String Function(Uri)> routes,
    List<Uri> log) {
  return MockClient((req) async {
    log.add(req.url);
    final q = req.url.queryParameters;
    final k = q['action'] ?? q['page'] ?? '';
    final r = routes[k];
    if (r == null) return http.Response('not found', 404);
    return http.Response.bytes(utf8.encode(r(req.url)), 200);
  });
}

Future<(int, Uint8List)> _fetch(String url) async {
  final c = HttpClient();
  try {
    final req = await c.getUrl(Uri.parse(url));
    req.headers.set('User-Agent', GoodShortSource.userAgent);
    final res = await req.close().timeout(const Duration(seconds: 90));
    final bytes = await res
        .fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d))
        .timeout(const Duration(seconds: 120));
    return (res.statusCode, bytes.takeBytes());
  } finally {
    c.close();
  }
}

/// Fetches [playlist], checks it's HLS, then fetches the first segment and
/// checks the MPEG-TS sync byte.
Future<void> _checkHls(String playlist) async {
  final (code, body) = await _fetch(playlist);
  expect(code, 200, reason: playlist);
  final pl = String.fromCharCodes(body);
  expect(pl, startsWith('#EXTM3U'));
  final seg = pl
      .split('\n')
      .map((l) => l.trim())
      .firstWhere((l) => l.isNotEmpty && !l.startsWith('#'));
  final (sc, sb) = await _fetch(Uri.parse(playlist).resolve(seg).toString());
  expect(sc, 200);
  expect(sb.length, greaterThan(376));
  expect(sb[0], 0x47, reason: 'MPEG-TS sync byte');
  // ignore: avoid_print
  print('  playlist ok, first segment ${sb.length}B TS');
}

void main() {
  group('goodshort parsers', () {
    test('detail maps 0-based site eps to 1-based app eps', () {
      final d = parseGoodShortDetail(fx('goodshort_detail.html'),
          id: '31001769950');
      expect(d.source, 'goodshort');
      expect(d.title, 'The Secret Babies');
      expect(d.cover, contains('goodreels.com'));
      expect(d.synopsis, startsWith('A short Romance Story!'));
      expect(d.totalEpisodes, 51);
      expect(d.episodes.first, 1);
      expect(d.episodes.last, 51);
      expect(d.episodes.length, 51);
    });

    test('chapterIds from the ep=-1 watch page', () {
      final ids = parseGoodShortChapterIds(fx('goodshort_watch_epm1.html'));
      expect(ids.length, 51);
      expect(ids.first, '66155558');
      expect(ids.last, '66155608');
      expect(parseGoodShortChapterIds('<html></html>'), isEmpty);
    });

    test('get_video_url -> HLS stream, qualities best first', () {
      final s = parseGoodShortVideo(fx('goodshort_get_video_url.json'),
          dramaId: '31001769950', ep: 51, server: 'server1');
      expect(s.isHls, isTrue);
      expect(s.playUrl,
          startsWith('https://cdn-goodshort.dramafren.org/proxy?token=v2.'));
      expect(s.qualities.map((q) => q.label), ['1080p', '720p', '540p']);
      expect(s.qualities.every((q) => q.isHls), isTrue);
    });

    test('get_video_url failure: next server, then locked', () {
      const bad = '{"status":"error","message":"Locked"}';
      expect(
          () => parseGoodShortVideo(bad,
              dramaId: 'x', ep: 3, server: 'server1'),
          throwsA(isA<SourceException>()
              .having((e) => e is EpisodeLockedException, 'locked', false)));
      expect(
          () => parseGoodShortVideo(bad,
              dramaId: 'x', ep: 3, server: 'server2', lastServer: true),
          throwsA(isA<EpisodeLockedException>()));
      expect(
          () => parseGoodShortVideo('<html>',
              dramaId: 'x', ep: 3, server: 'server1'),
          throwsA(isA<SourceException>()));
    });

    test('proxy playlist fixture is plain HLS with absolute proxy segments',
        () {
      final pl = fx('goodshort_proxy_ep51.m3u8');
      expect(pl, startsWith('#EXTM3U'));
      expect(pl, isNot(contains('EXT-X-KEY')));
      expect(pl, contains('https://cdn-goodshort.dramafren.org/proxy?token='));
    });
  });

  group('goodshort source (mock http)', () {
    test('search/feed/detail/episode request shapes + chapterIds cache',
        () async {
      final log = <Uri>[];
      final src = GoodShortSource(
        client: fakeClient({
          'search_result': (_) => fx('goodshort_search.html'),
          'home': (_) => fx('goodshort_home_cdn.html'),
          'detail': (_) => fx('goodshort_detail.html'),
          'watch': (_) => fx('goodshort_watch_epm1.html'),
          'get_video_url': (_) => fx('goodshort_get_video_url.json'),
        }, log),
      );
      final res = await src.search('love');
      expect(res, isNotEmpty);
      expect(res.first.source, 'goodshort');
      expect(res.first.id, '31001122854');
      expect(res.first.episodes, 87);
      expect(log.last.queryParameters['page'], 'search_result');
      expect(log.last.queryParameters['lang'], 'en');

      final feed = await src.feed(1);
      expect(feed.items.length, 12);
      expect(feed.hasMore, isTrue);
      expect(feed.items.first.id, '31001769950');

      final d = await src.detail(const Drama(
          source: 'goodshort', id: '31001769950', title: 't', cover: ''));
      expect(src.servers(d), ['server1', 'server2']);

      final s1 = await src.episode(d, 1, server: 'server1');
      expect(s1.isHls, isTrue);
      var q = log.last.queryParameters;
      expect(q['action'], 'get_video_url');
      expect(q['chap_id'], '66155558'); // app ep 1 -> site ep 0
      expect(q['sv'], '1');
      final watches =
          log.where((u) => u.queryParameters['page'] == 'watch').toList();
      expect(watches.single.queryParameters['ep'], '-1');

      await src.episode(d, 51, server: 'server2');
      q = log.last.queryParameters;
      expect(q['chap_id'], '66155608'); // last chapter
      expect(q['sv'], '2');
      // chapterIds cached: still a single watch-page fetch.
      expect(log.where((u) => u.queryParameters['page'] == 'watch').length, 1);

      expect(() => src.episode(d, 52, server: 'server1'),
          throwsA(isA<EpisodeLockedException>()));
    });

    test('retries once on 5xx, then surfaces SourceException', () async {
      var calls = 0;
      final src = GoodShortSource(
        client: MockClient((req) async {
          calls++;
          return http.Response('bad gateway', 502);
        }),
      );
      await expectLater(src.search('x'), throwsA(isA<SourceException>()));
      expect(calls, 2);
    });
  });

  group('flickreels parsers', () {
    test('watch page -> m3u8 (JSON-unescaped)', () {
      final u = flickReelsVideoUrlOf(fx('flickreels_watch_ep40.html'));
      expect(u, isNotNull);
      expect(u, startsWith('https://zshipricf.farsunpteltd.'));
      expect(u, contains('.m3u8?verify='));
      expect(u, isNot(contains(r'\/')));
      expect(u, contains('hls_1789897109_40_33292'));
    });

    test('empty initialVideoUrl -> null', () {
      expect(flickReelsVideoUrlOf('var initialVideoUrl = "";'), isNull);
      expect(flickReelsVideoUrlOf('<html></html>'), isNull);
      expect(
          flickReelsVideoUrlOf(
              '<video id="player" src="https://h/x.m3u8?verify=1"></video>'),
          'https://h/x.m3u8?verify=1');
    });

    test('ep40 playlist fixture: relative TS segments, no key', () {
      final pl = fx('flickreels_ep40.m3u8');
      expect(pl, startsWith('#EXTM3U'));
      expect(pl, isNot(contains('EXT-X-KEY')));
      expect(pl, contains('-00001.ts'));
    });
  });

  group('flickreels source (mock http)', () {
    test('search/feed/detail/episode', () async {
      final log = <Uri>[];
      final src = FlickReelsSource(
        client: fakeClient({
          'search_result': (_) => fx('flickreels_search.html'),
          'home': (_) => fx('flickreels_home.html'),
          'detail': (_) => fx('flickreels_detail.html'),
          'watch': (_) => fx('flickreels_watch_ep40.html'),
        }, log),
      );
      final res = await src.search('love');
      expect(res.length, 12);
      expect(res.first.source, 'flickreels');
      expect(res.first.id, '10486');
      expect(res.every((d) => d.title.isNotEmpty), isTrue);

      final feed = await src.feed(1);
      expect(feed.items.length, 12);
      expect(feed.hasMore, isTrue);
      expect(log.last.queryParameters['lang'], 'en');

      final d = await src.detail(const Drama(
          source: 'flickreels', id: '12153', title: 't', cover: ''));
      expect(d.totalEpisodes, 40);
      expect(d.episodes.first, 1);
      expect(d.episodes.last, 40);
      expect(d.title, isNotEmpty);
      expect(d.cover, startsWith('http'));
      expect(src.servers(d), ['server1']);

      final s = await src.episode(d, 40, server: 'server1');
      expect(s.isHls, isTrue);
      expect(s.playUrl, contains('.m3u8?verify='));
      expect(log.last.queryParameters['ep'], '40');
      // Not cached: a second call refetches the watch page.
      await src.episode(d, 40, server: 'server1');
      expect(log.where((u) => u.queryParameters['page'] == 'watch').length, 2);
    });

    test('missing stream -> EpisodeLockedException', () async {
      final src = FlickReelsSource(
        client: MockClient((req) async =>
            http.Response('<html>var initialVideoUrl = "";</html>', 200)),
      );
      const d = DramaDetail(
          source: 'flickreels',
          id: '1',
          title: 't',
          cover: '',
          synopsis: '',
          totalEpisodes: 1,
          episodes: [1]);
      await expectLater(src.episode(d, 1, server: 'server1'),
          throwsA(isA<EpisodeLockedException>()));
    });
  });

  group('live', () {
    setUpAll(() => HttpOverrides.global = null);
    const skip = 'set LIVE=1 to run live network tests';

    test('goodshort: search -> detail -> ep 1 + last -> playlist', () async {
      final src = GoodShortSource();
      final res = await src.search('love');
      expect(res, isNotEmpty);
      // ignore: avoid_print
      print('goodshort search: ${res.length} items, first=${res.first.id} '
          '${res.first.title} eps=${res.first.episodes}');
      final d = await src.detail(res.first);
      expect(d.episodes, isNotEmpty);
      // ignore: avoid_print
      print('goodshort detail: ${d.title} / ${d.totalEpisodes} eps '
          '(${d.episodes.first}..${d.episodes.last})');
      // Resolve both first (cheap JSON), then fetch playlists: the proxied
      // playlist is the slow part when the backend is cold.
      final streams = <int, String>{};
      for (final ep in {d.episodes.first, d.episodes.last}) {
        final s = await src.episode(d, ep, server: 'server1');
        expect(s.isHls, isTrue);
        streams[ep] = s.playUrl;
        // ignore: avoid_print
        print('goodshort ep $ep: ${s.playUrl.substring(0, 80)}... '
            'qualities=${s.qualities.map((q) => q.label).toList()}');
      }
      for (final e in streams.entries) {
        // ignore: avoid_print
        print('goodshort ep ${e.key} playlist:');
        await _checkHls(e.value);
      }
    },
        skip: _live ? false : skip,
        timeout: const Timeout(Duration(minutes: 8)));

    test('flickreels: search -> detail -> ep 1 + last -> playlist', () async {
      final src = FlickReelsSource();
      final res = await src.search('love');
      expect(res, isNotEmpty);
      // ignore: avoid_print
      print('flickreels search: ${res.length} items, first=${res.first.id} '
          '${res.first.title}');
      final d = await src.detail(res.first);
      expect(d.episodes, isNotEmpty);
      // ignore: avoid_print
      print('flickreels detail: ${d.title} / ${d.totalEpisodes} eps');
      for (final ep in {d.episodes.first, d.episodes.last}) {
        final s = await src.episode(d, ep, server: 'server1');
        expect(s.isHls, isTrue);
        // ignore: avoid_print
        print('flickreels ep $ep: ${s.playUrl.substring(0, 80)}...');
        await _checkHls(s.playUrl);
      }
    },
        skip: _live ? false : skip,
        timeout: const Timeout(Duration(minutes: 2)));
  });
}
