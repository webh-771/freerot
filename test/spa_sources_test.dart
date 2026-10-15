import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shortmax_player/data/source.dart';
import 'package:shortmax_player/data/sources/microdrama_source.dart';
import 'package:shortmax_player/data/sources/shortwave_source.dart';
import 'package:shortmax_player/data/web/web_session.dart';
import 'package:shortmax_player/models.dart';

String fixture(String name) => File('probes/fixtures/$name').readAsStringSync();

Map<String, dynamic> fixtureJson(String name) =>
    (jsonDecode(fixture(name)) as Map).cast<String, dynamic>();

/// Fake WebSession fetch: routes by `api_route` to a fixture body.
Future<String> Function(String) fakeFetch(
  Map<String, String> byRoute,
  List<String> log,
) {
  return (url) async {
    log.add(url);
    final route = Uri.parse(url).queryParameters['api_route'];
    final body = byRoute[route];
    if (body == null) throw StateError('unexpected route $route');
    return body;
  };
}

void main() {
  group('microdrama', () {
    test('list', () {
      final l = MicroDramaSource.parseDramaList(
        fixtureJson('microdrama_list.json'),
      );
      expect(l.length, 3);
      final d = l.first;
      expect(d.source, 'microdrama');
      expect(d.id, '2100422082557042689');
      expect(d.title, "The Mafia'S Stolen Bride");
      expect(d.episodes, 40);
      expect(d.cover, startsWith('https://poster.janzhoutec.com/'));
      expect(d.synopsis, startsWith('Sabrina wakes'));
      expect(d.key, 'microdrama:2100422082557042689');
    });

    test('search', () {
      final l = MicroDramaSource.parseDramaList(
        fixtureJson('microdrama_search.json'),
      );
      expect(l.length, 3);
      expect(l.first.title, 'One Night with My Billionaire CEO');
      expect(l.first.episodes, 62);
      expect(
        MicroDramaSource.parseDramaList({'total': 0, 'dramas': []}),
        isEmpty,
      );
    });

    test('detail', () {
      final d = MicroDramaSource.parseDetail(
        fixtureJson('microdrama_detail.json'),
      );
      expect(d.detail.source, 'microdrama');
      expect(d.detail.id, '2100422082557042689');
      expect(d.detail.title, "The Mafia'S Stolen Bride");
      expect(d.detail.totalEpisodes, 40);
      expect(d.detail.episodes, [1, 2, 40]);
      expect(d.detail.locked, isEmpty);
      expect(d.detail.synopsis, startsWith('Sabrina wakes'));
      expect(d.videos[40]!.length, 4);
      // auth_key expiry 1790339076 (earliest in the fixture).
      expect(d.expiresAt!.millisecondsSinceEpoch ~/ 1000, 1790339076);
    });

    test('quality ordering + stream', () {
      final d = MicroDramaSource.parseDetail(
        fixtureJson('microdrama_detail.json'),
      );
      final s = MicroDramaSource.buildStream(d, 1);
      expect(
        [for (final q in s.qualities) q.label],
        ['720p', '540p', '480p', '360p'],
      );
      expect(s.qualities.every((q) => !q.isHls), isTrue);
      expect(s.isHls, isFalse);
      expect(s.playUrl, s.qualities.first.url);
      expect(s.playUrl, contains('oIrc4VGQxE1Sm2zCJyLASYIOqaeaZbTIAsic9I'));
      expect(s.playUrl, contains('auth_key='));
      expect(s.dramaId, '2100422082557042689');
      expect(s.ep, 1);
      expect(s.server, '1');
      expect(s.proxyUrl, '');
      expect(s.headers, isEmpty);
    });

    test('missing episode is locked', () {
      final d = MicroDramaSource.parseDetail(
        fixtureJson('microdrama_detail.json'),
      );
      expect(
        () => MicroDramaSource.buildStream(d, 3),
        throwsA(isA<EpisodeLockedException>()),
      );
    });

    test('episode without videos is marked locked', () {
      final d = MicroDramaSource.parseDetail({
        'drama': {'id': '1', 'title': 'T', 'cover': '', 'episodes': 2},
        'episodes': [
          {
            'index': 1,
            'videos': [
              {'quality': '540P', 'url': 'https://x/a.mp4'},
            ],
          },
          {'index': 2, 'videos': []},
        ],
      });
      expect(d.detail.locked, {2});
      expect(MicroDramaSource.buildStream(d, 1).playUrl, 'https://x/a.mp4');
      expect(
        () => MicroDramaSource.buildStream(d, 2),
        throwsA(isA<EpisodeLockedException>()),
      );
    });

    test('shape errors', () {
      expect(
        () => MicroDramaSource.decodeApi(
          '{"error":"Failed to fetch data and no cache available"}',
          'detail',
        ),
        throwsA(
          isA<SourceException>().having(
            (e) => e.message,
            'message',
            contains('Failed'),
          ),
        ),
      );
      expect(
        () => MicroDramaSource.decodeApi('<html>Just a moment', 'list'),
        throwsA(isA<SourceException>()),
      );
      expect(
        () => MicroDramaSource.parseDetail({'foo': 1}),
        throwsA(isA<SourceException>()),
      );
      expect(
        () => MicroDramaSource.parseDramaList({'dramas': 'x'}),
        throwsA(isA<SourceException>()),
      );
    });

    test('source: feed/search/detail/episode via fake fetch', () async {
      final log = <String>[];
      final src = MicroDramaSource(
        fetch: fakeFetch({
          'list': fixture('microdrama_list.json'),
          'search': fixture('microdrama_search.json'),
          'detail': fixture('microdrama_detail.json'),
        }, log),
      );
      expect(src.key, 'microdrama');
      expect(src.label('microdrama'), 'MicroDrama');
      expect(src.handles('microdrama'), isTrue);
      expect(src.handles('shortwave'), isFalse);

      final f = await src.feed(1);
      expect(f.items.length, 3);
      expect(f.hasMore, isFalse);
      expect((await src.feed(2)).items, isEmpty);
      expect(
        log.single,
        'https://microdrama.dramafren.org/?api_route=list&lang=en&page=1',
      );

      expect(await src.search('  '), isEmpty);
      final s = await src.search('love story');
      expect(s.length, 3);
      final su = Uri.parse(log.last);
      expect(su.queryParameters['q'], 'love story');
      expect(su.queryParameters['lang'], 'en');

      final det = await src.detail(f.items.first);
      expect(src.servers(det), ['1']);
      final n = log.length;
      final st = await src.episode(det, 40, server: '1');
      // Detail is cached: no extra request (fixture expiry is 2026-09-25;
      // only true if run before then, so don't assert request count after).
      if (DateTime.now().isBefore(
        DateTime.fromMillisecondsSinceEpoch(1790339076000 - 700000),
      )) {
        expect(log.length, n);
      }
      expect(st.ep, 40);
      expect(st.qualities.first.label, '720p');
      expect(
        Uri.parse(log[n - 1]).queryParameters['id'],
        '2100422082557042689',
      );
    });

    test('NeedsVerificationException propagates unchanged', () async {
      final src = MicroDramaSource(
        fetch: (_) async =>
            throw NeedsVerificationException(MicroDramaSource.origin),
      );
      await expectLater(
        src.feed(1),
        throwsA(isA<NeedsVerificationException>()),
      );
      await expectLater(
        src.search('ceo'),
        throwsA(isA<NeedsVerificationException>()),
      );
    });
  });

  group('shortwave', () {
    test('list', () {
      final l = ShortWaveSource.parseDramaList(
        fixtureJson('shortwave_list.json'),
      );
      expect(l.length, 3);
      expect(l.first.source, 'shortwave');
      expect(l.first.id, '6ab3b019da8012969fdd38a4');
      expect(l.first.title, 'Astroward');
      expect(l.first.episodes, 35);
      expect(l.first.cover, 'https://s.shortswave.com/image/cover/36110.webp');
      expect(l.first.synopsis, isNull);
    });

    test('search', () {
      final l = ShortWaveSource.parseDramaList(
        fixtureJson('shortwave_search.json'),
      );
      expect(l.map((d) => d.title), contains('Married Into Love'));
      expect(l[1].episodes, 57);
    });

    test('detail', () {
      final d = ShortWaveSource.parseDetail(
        fixtureJson('shortwave_detail.json'),
        fallback: const Drama(
          source: 'shortwave',
          id: '6ab3b019da8012969fdd38a4',
          title: 'Astroward',
          cover: '',
          episodes: 35,
        ),
      );
      expect(d.detail.id, '6ab3b019da8012969fdd38a4');
      expect(d.detail.title, 'Astroward');
      expect(d.detail.synopsis, startsWith('Reborn at the familiar-binding'));
      expect(d.detail.cover, 'https://s.shortswave.com/image/cover/36110.webp');
      expect(d.detail.episodes, [1, 2, 7, 8, 35]);
      expect(d.detail.totalEpisodes, 35);
      expect(d.detail.locked, isEmpty);
      expect(d.chapters[35], '6ab3b028da8012969fdd38ba');
      expect(d.chapters[1], '6ab3b022da8012969fdd38b1');
      expect(d.paid, {7, 8, 35});
    });

    test('detail total falls back to max index', () {
      final d = ShortWaveSource.parseDetail(
        fixtureJson('shortwave_detail.json'),
      );
      expect(d.detail.totalEpisodes, 35);
    });

    test('unlock → EpisodeStream', () {
      final s = ShortWaveSource.parseUnlock(
        fixtureJson('shortwave_unlock_locked_ep35.json'),
        dramaId: '6ab3b019da8012969fdd38a4',
        ep: 35,
      );
      expect(
        s.playUrl,
        'https://api.shortswave.com/v1/play/6ab3b028da8012969fdd38ba/v.m3u8?auth_key=720pacd1baa5e01a425a8c9f3ab8189d44af',
      );
      expect(s.isHls, isTrue);
      expect(s.qualities.single.isHls, isTrue);
      expect(s.qualities.single.url, s.playUrl);
      expect(s.server, '1');
      expect(s.ep, 35);
      expect(s.proxyUrl, '');
      expect(s.subtitles, isEmpty);
      expect(s.headers, isEmpty);
    });

    test('unlock errors', () {
      expect(
        () => ShortWaveSource.parseUnlock(
          {'code': 1, 'msg': 'nope'},
          dramaId: 'x',
          ep: 1,
        ),
        throwsA(isA<SourceException>()),
      );
      expect(
        () => ShortWaveSource.parseUnlock(
          {
            'code': 0,
            'data': {'play_url_encoded': '', 'play_url_720p': ''},
          },
          dramaId: 'x',
          ep: 1,
        ),
        throwsA(isA<EpisodeLockedException>()),
      );
      expect(
        () => ShortWaveSource.parseUnlock(
          {
            'code': 0,
            'data': {'play_url_encoded': '%%%notb64'},
          },
          dramaId: 'x',
          ep: 1,
        ),
        throwsA(isA<SourceException>()),
      );
      // url-safe base64 without padding also decodes.
      final enc = base64Url
          .encode(
            utf8.encode('https://api.shortswave.com/v1/play/a/v.m3u8?x=1'),
          )
          .replaceAll('=', '');
      expect(
        ShortWaveSource.decodePlayUrl(enc),
        'https://api.shortswave.com/v1/play/a/v.m3u8?x=1',
      );
    });

    test('repeat page detection', () {
      expect(ShortWaveSource.isRepeatPage(['a', 'b'], ['a', 'b']), isTrue);
      expect(ShortWaveSource.isRepeatPage(['a', 'b'], ['a', 'c']), isFalse);
      expect(ShortWaveSource.isRepeatPage(['a'], null), isFalse);
    });

    test('source: feed/detail/episode via fake fetch', () async {
      final log = <String>[];
      final fullPage = jsonEncode({
        'dramas': [
          for (var i = 0; i < 24; i++)
            {'id': 'id$i', 'title': 'T$i', 'cover': '', 'episodes': 10},
        ],
      });
      final routes = {
        'list': fullPage,
        'detail': fixture('shortwave_detail.json'),
        'unlock': fixture('shortwave_unlock_locked_ep35.json'),
        'search': fixture('shortwave_search.json'),
      };
      final src = ShortWaveSource(fetch: fakeFetch(routes, log));
      expect(src.key, 'shortwave');
      expect(src.label('shortwave'), 'ShortWave');

      final p1 = await src.feed(1);
      expect(p1.items.length, 24);
      expect(p1.hasMore, isTrue);
      expect(
        log.last,
        'https://shortwave.dramafren.org/?api_route=list&lang=en&page=1',
      );
      // Server repeats the last page past the end → stop.
      final p2 = await src.feed(2);
      expect(p2.items, isEmpty);
      expect(p2.hasMore, isFalse);

      routes['list'] = fixture('shortwave_list.json');
      final short = await src.feed(3);
      expect(short.items.length, 3);
      expect(short.hasMore, isFalse);

      expect((await src.search('love')).length, 3);

      final det = await src.detail(
        const Drama(
          source: 'shortwave',
          id: '6ab3b019da8012969fdd38a4',
          title: 'Astroward',
          cover: '',
        ),
      );
      final st = await src.episode(det, 35, server: '1');
      final u = Uri.parse(log.last);
      expect(u.queryParameters['api_route'], 'unlock');
      expect(u.queryParameters['drama_id'], '6ab3b019da8012969fdd38a4');
      expect(u.queryParameters['chapter_id'], '6ab3b028da8012969fdd38ba');
      expect(st.playUrl, startsWith('https://api.shortswave.com/v1/play/'));

      // Unknown episode → locked.
      await expectLater(
        src.episode(det, 3, server: '1'),
        throwsA(isA<EpisodeLockedException>()),
      );
    });

    test('NeedsVerificationException propagates unchanged', () async {
      final src = ShortWaveSource(
        fetch: (_) async =>
            throw NeedsVerificationException(ShortWaveSource.origin),
      );
      await expectLater(
        src.feed(1),
        throwsA(isA<NeedsVerificationException>()),
      );
      await expectLater(
        src.search('love'),
        throwsA(isA<NeedsVerificationException>()),
      );
    });
  });
}
