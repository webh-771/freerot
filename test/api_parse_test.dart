import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shortmax_player/data/official_crypto.dart';
import 'package:shortmax_player/data/parsers.dart';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

void main() {
  group('detail', () {
    final d = parseDetail(fixture('detail.html'), '858981');

    test('title decoded', () {
      expect(d.title, "Too Late for My Shifters' Regret");
    });
    test('episodes', () {
      expect(d.totalEpisodes, 90);
      expect(d.episodes.length, 90);
      expect(d.episodes.first, 1);
      expect(d.episodes.last, 90);
      final sorted = [...d.episodes]..sort();
      expect(d.episodes, sorted);
    });
    test('cover + synopsis', () {
      expect(d.cover, startsWith('https://akamai-static.shorttv.live/'));
      expect(d.cover, contains('auth_key='));
      expect(d.cover, isNot(contains('&amp;')));
      expect(d.synopsis, startsWith('After exhausting her power'));
      expect(d.synopsis, isNot(contains('Ep 1')));
    });
    test('missing drama throws', () {
      expect(
        () => parseDetail('<html><body>nothing</body></html>', '1'),
        throwsA(isA<ShortMaxException>()),
      );
    });
    test('fallback episode list from total', () {
      final x = parseDetail(
        '<h1>X &#039;Y</h1><span>Total: 5 Eps</span><p class="text-slate-300">s</p>',
        '7',
      );
      expect(x.title, "X 'Y");
      expect(x.episodes, [1, 2, 3, 4, 5]);
    });
  });

  group('search', () {
    final p = parseSearch(fixture('search.html'), 1);
    test('many results with ids, covers, eps', () {
      expect(p.items.length, greaterThan(20));
      final first = p.items.first;
      expect(first.id, '857607');
      expect(first.title, 'Taming the Starved Merman CEO');
      expect(first.episodes, 20);
      expect(first.cover, startsWith('https://'));
      expect(first.cover, isNot(contains('&amp;')));
      expect(p.items.map((e) => e.id).toSet().length, p.items.length);
    });
    test('hasMore', () {
      expect(p.hasMore, isTrue);
      final last = fixture('search.html').replaceAll(
        RegExp(r'<a href="index.php\?page=search_result[^>]*>[^<]*</a>'),
        '',
      );
      expect(parseSearch(last, 1).hasMore, isFalse);
    });
  });

  group('home recent', () {
    final p = parseRecent(fixture('home.html'), 1);
    test('cards', () {
      expect(p.items.length, 12);
      expect(p.items.first.id, '35953');
      expect(p.items.first.title, 'Reborn for the Raven Prince');
      expect(p.items.first.cover, startsWith('https://'));
    });
    test('hasMore from Page X of Y', () {
      expect(p.hasMore, isTrue);
    });
    test('relative cover resolved', () {
      final r = parseRecent(
        '<a href="index.php?page=detail&amp;id=5"><img src="img/c.jpg" alt="A &amp; B"></a><span>Page 9 of 9</span>',
        9,
      );
      expect(r.items.single.cover, 'https://shortmax.ngeshorts.fun/img/c.jpg');
      expect(r.items.single.title, 'A & B');
      expect(r.hasMore, isFalse);
    });
  });

  group('video server', () {
    test('server1 qualities sorted', () {
      final s = parseEpisodeStream(
        fixture('video_server1.json'),
        '858981',
        50,
        'server1',
      );
      expect(s.server, 'server1');
      expect(s.qualities.map((q) => q.label), ['1080p', '720p', '480p']);
      expect(s.qualities.first.url, contains('_1080/main.m3u8'));
      expect(s.playUrl, contains('_720/main.m3u8'));
      expect(s.proxyUrl, contains('action=proxy_video'));
    });
    test('server2', () {
      final s = parseEpisodeStream(
        fixture('video_server2.json'),
        '858981',
        50,
        'server2',
      );
      expect(s.server, 'server2');
      expect(s.qualities.map((q) => q.label), ['1080p', '720p', '480p']);
    });
    test('ok=false throws', () {
      expect(
        () => parseEpisodeStream(
          '{"ok":false,"message":"Server unavailable"}',
          '1',
          1,
          'server1',
        ),
        throwsA(isA<ShortMaxException>()),
      );
    });
  });

  group('official', () {
    test('AES round trip', () {
      final ct = officialEncrypt({'pageNo': 1, 'pageSize': 24});
      expect(officialDecrypt(ct), {'pageNo': 1, 'pageSize': 24});
    });
    test('queryPage mapping', () {
      final p = parseOfficialPage(
        {
          'total': 30,
          'list': [
            {
              'shortPlayId': 1,
              'shortPlayCode': '867551',
              'shortPlayName': 'Raw',
              'lanShortPlayName': 'Lan',
              'coverId': 'c',
              'lanCoverId': 'lc',
              'summary': 's',
            },
            {'shortPlayId': 2, 'shortPlayName': 'NoCode', 'coverId': 'c'},
            {'shortPlayCode': 42, 'shortPlayName': 'Raw2', 'coverId': 'c2'},
          ],
        },
        1,
        24,
      );
      expect(p.items.length, 2);
      expect(p.items[0].id, '867551');
      expect(p.items[0].title, 'Lan');
      expect(p.items[0].cover, 'lc');
      expect(p.items[1].id, '42');
      expect(p.items[1].title, 'Raw2');
      expect(p.items[1].cover, 'c2');
      expect(p.hasMore, isTrue);
      expect(
        parseOfficialPage({'total': 30, 'list': []}, 2, 24).hasMore,
        isFalse,
      );
    });
    test('categories', () {
      final c = parseCategories([
        {'classId': 200042, 'displayName': 'Teen Drama', 'rawName': 'x'},
        {'classId': 200029, 'rawName': 'Mutation'},
        {'displayName': 'no id'},
      ]);
      expect(c.map((e) => e.classId), [200042, 200029]);
      expect(c.map((e) => e.name), ['Teen Drama', 'Mutation']);
    });
  });
}
