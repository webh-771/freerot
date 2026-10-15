// Parser + source tests for the dramafren PHP template sources (idrama,
// stardust, starshort, dramabite) against the saved fixtures in
// probes/fixtures. CF sources are exercised with a fake page fetcher.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shortmax_player/data/source.dart';
import 'package:shortmax_player/data/sources/dramabite_source.dart';
import 'package:shortmax_player/data/sources/idrama_source.dart';
import 'package:shortmax_player/data/sources/php_template.dart';
import 'package:shortmax_player/data/sources/stardust_source.dart';
import 'package:shortmax_player/data/sources/starshort_source.dart';
import 'package:shortmax_player/models.dart';

String fx(String name) => File('probes/fixtures/$name').readAsStringSync();

/// Fake fetcher: picks a fixture by the `page` query param and logs URLs.
class FakePages {
  final Map<String, String> byPage;
  final List<Uri> requested = [];
  FakePages(this.byPage);

  Future<String> call(String url) async {
    final u = Uri.parse(url);
    requested.add(u);
    final p = u.queryParameters['page'] ??
        (u.queryParameters.containsKey('hp') ? 'home' : '');
    final f = byPage[p];
    if (f == null) throw StateError('no fixture for $url');
    return fx(f);
  }
}

void main() {
  group('template parsers', () {
    test('cards: stardust feed after "Recently Watched"', () {
      final cards = parseTemplateCards(fx('stardusttv_home.html'),
          after: 'Recently Watched');
      expect(cards.length, 24);
      final c = cards.first;
      expect(c.id, '18221');
      expect(c.slug, 'goddess-system-now-she-begs');
      expect(c.title, 'Goddess System: Now She Begs');
      expect(c.cover, startsWith('https://assets.stardusttv.cc/'));
      expect(cards.map((e) => e.id).toSet().length, cards.length);
    });

    test('cards: idrama search has episode badges', () {
      final cards = parseTemplateCards(fx('idrama_search.html'));
      expect(cards.length, 20);
      expect(cards.first.id, '100000640887');
      expect(cards.first.title, 'Love after Layoffs');
      expect(cards.first.episodes, 89);
      expect(cards.first.cover, startsWith('https://p.idrama.video/'));
    });

    test('cards: starshort search placeholders become empty covers', () {
      final cards = parseTemplateCards(fx('starshort_search.html'));
      expect(cards.length, 10);
      expect(cards.first.id, 'l9V');
      expect(cards.first.title, 'Love Me First Love Me Forever');
      expect(cards.every((c) => c.cover.isEmpty), isTrue);
    });

    test('pager: Next » detection', () {
      expect(templateHasNext(fx('stardusttv_home.html'), 'hp', 1), isTrue);
      expect(templateHasNext(fx('stardusttv_home.html'), 'hp', 2), isFalse);
      expect(templateHasNext(fx('starshort_home.html'), 'p_hist', 1), isTrue);
      expect(templateHasNext(fx('idrama_home_cdnhost.html'), 'p_hist', 1),
          isFalse);
      expect(templateHasNext(fx('stardusttv_search.html'), 'p', 1), isTrue);
      expect(templatePageOf(fx('stardusttv_search.html')), (1, 58));
      expect(templatePageOf('Page <span>1</span> of 25'), (1, 25));
    });

    test('detail: idrama', () {
      final d = parseTemplateDetail(fx('idrama_detail.html'));
      expect(d.title, 'He Chose His Adopted Sister, So I Chose Another Man');
      expect(d.total, 20);
      expect(d.episodes, List.generate(20, (i) => i + 1));
      expect(d.cover, startsWith('https://p.idrama.video/group1/'));
      expect(d.synopsis, startsWith('Blair Bennett'));
    });

    test('detail: stardust placeholder synopsis dropped', () {
      final d = parseTemplateDetail(fx('stardusttv_detail.html'));
      expect(d.title, 'The Fighter Who Refused to Kneel');
      expect(d.total, 51);
      expect(d.episodes.length, 51);
      expect(d.synopsis, isEmpty);
      expect(d.cover, contains('960672699475648512.jpg'));
    });

    test('detail: starshort + dramabite', () {
      final s = parseTemplateDetail(fx('starshort_detail.html'));
      expect(s.title, 'My professor is an S-class anomaly');
      expect(s.total, 45);
      expect(s.episodes.length, 45);
      expect(s.synopsis, startsWith('Twenty-one-year-old'));
      expect(s.cover, startsWith('https://bsy-cdp-img.wolftv.online/'));

      final b = parseTemplateDetail(fx('dramabite_detail.html'));
      expect(b.title, 'Waking Vow');
      expect(b.total, 65);
      expect(b.episodes.length, 65);
      expect(b.episodes.last, 65);
      expect(b.cover, startsWith('https://cdn-oss.miniepisode.media/'));
    });

    test('watch: stardust encryptedSrc', () {
      expect(
        watchVideoUrlOf(fx('stardusttv_watch_ep1.html')),
        'https://acdn-v.stardust-tv.com/prod/22901/1/'
        'cebf4bdecff84a5c925c75d5c2e7da96.m3u8',
      );
    });

    test('watch: starshort encryptedSrc + qualities + auth_key expiry', () {
      final html = fx('starshort_watch.html');
      final url = watchVideoUrlOf(html)!;
      expect(url, startsWith('https://bsyvideo.wolftv.online/'));
      expect(url, contains('-sd.m3u8?auth_key=1790135701-0-0-'));
      expect(authKeyExpiry(url), 1790135701);
      final q = availableQualitiesOf(html);
      expect(q.single.label, 'Auto (HLS)');
      expect(q.single.url, url);
    });

    test('watch: dramabite atob(videoSrc)', () {
      final url = watchVideoUrlOf(fx('dramabite_watch.html'))!;
      expect(url, startsWith('https://cdn-video.miniepisode.media/video/16221/1/'));
      expect(url, contains('wsSecret='));
      expect(availableQualitiesOf(fx('dramabite_watch.html')), isEmpty);
    });

    test('watch: empty src and hash64 qualities', () {
      expect(watchVideoUrlOf('const encryptedSrc = "";'), isNull);
      final q = availableQualitiesOf(
        'const availableQualities = [{"quality":"720p","hash64":'
        '"aHR0cHM6Ly9hL2IubTN1OA=="}];',
      );
      expect(q.single.url, 'https://a/b.m3u8');
      expect(q.single.label, '720p');
    });

    test('idrama watch_stream JSON', () {
      final s = parseIDramaStream(fx('idrama_watch_stream.json'),
          dramaId: '100000644441', ep: 1, server: 'server1');
      expect(s.playUrl, startsWith('https://v-a.idrama.video/'));
      expect(s.playUrl, contains('.m3u8?ts=1790181457&secret='));
      expect(s.proxyUrl, contains('action=proxy_video'));
      expect(s.isHls, isTrue);
      expect(
        () => parseIDramaStream('{"ok":false,"error":"nope"}',
            dramaId: 'x', ep: 1, server: 'server1'),
        throwsA(isA<SourceException>()),
      );
    });
  });

  group('sources over fixtures', () {
    test('stardust: feed/search/detail/episode + slug ids', () async {
      final pages = FakePages({
        'home': 'stardusttv_home.html',
        'search_result': 'stardusttv_search.html',
        'detail': 'stardusttv_detail.html',
        'watch': 'stardusttv_watch_ep1.html',
      });
      final src = StardustSource(fetch: pages.call);
      expect(src.key, 'stardust');
      expect(src.label('stardust'), 'StardustTV');

      final feed = await src.feed(1);
      expect(feed.items.length, 24);
      expect(feed.hasMore, isTrue);
      expect(feed.items.first.id, '18221/goddess-system-now-she-begs');
      expect(pages.requested.last.queryParameters['hp'], '1');

      final res = await src.search('love');
      expect(res.first.id, '21407/illicit-love');
      expect(res.first.source, 'stardust');

      final d = await src.detail(res.first);
      final q = pages.requested.last.queryParameters;
      expect(q['id'], '21407');
      expect(q['slug'], 'illicit-love');
      expect(d.id, '21407/illicit-love');
      expect(d.totalEpisodes, 51);

      final s = await src.episode(d, 1, server: src.servers(d)[1]);
      final w = pages.requested.last.queryParameters;
      expect(w['sv'], '2');
      expect(w['slug'], 'illicit-love');
      expect(s.playUrl, endsWith('.m3u8'));
      expect(s.isHls, isTrue);
      expect(s.server, 'server2');
    });

    test('starshort: expired auth_key -> SourceException (next server)',
        () async {
      final pages = FakePages({
        'watch': 'starshort_watch.html',
        'detail': 'starshort_detail.html',
      });
      final d = DramaDetail(
        source: 'starshort',
        id: 'AX0',
        title: 't',
        cover: '',
        synopsis: '',
        totalEpisodes: 45,
        episodes: List.generate(45, (i) => i + 1),
      );
      final fresh = StarShortSource(
        fetch: pages.call,
        now: () => DateTime.fromMillisecondsSinceEpoch(1790135701000 - 3600000),
      );
      final s = await fresh.episode(d, 1, server: 'server1');
      expect(s.playUrl, contains('auth_key=1790135701'));
      expect(pages.requested.last.queryParameters['lang'], '3');
      expect(pages.requested.last.queryParameters['server'], '1');

      final stale = StarShortSource(
        fetch: pages.call,
        now: () => DateTime.fromMillisecondsSinceEpoch(1790135701000 + 1000),
      );
      await expectLater(stale.episode(d, 1, server: 'server1'),
          throwsA(isA<SourceException>()));
    });

    test('starshort: search fills covers from detail pages', () async {
      final pages = FakePages({
        'search_result': 'starshort_search.html',
        'detail': 'starshort_detail.html',
      });
      final src = StarShortSource(fetch: pages.call);
      final res = await src.search('love');
      expect(res.length, 10);
      expect(res.every((d) => d.cover.startsWith('https://bsy-cdp-img')),
          isTrue);
    });

    test('dramabite: feed/detail/episode', () async {
      final pages = FakePages({
        'home': 'dramabite_home.html',
        'detail': 'dramabite_detail.html',
        'watch': 'dramabite_watch.html',
      });
      final src = DramaBiteSource(fetch: pages.call);
      expect(src.label('dramabite'), 'DramaBite');
      final feed = await src.feed(1);
      expect(feed.items.length, 12);
      expect(feed.hasMore, isTrue);
      expect(feed.items.first.id, '16221');
      expect(feed.items.first.title, 'Waking Vow');
      expect(pages.requested.last.queryParameters['p_hist'], '1');
      final d = await src.detail(feed.items.first);
      expect(d.totalEpisodes, 65);
      final s = await src.episode(d, 1, server: 'server1');
      expect(s.playUrl, contains('miniepisode.media'));
      expect(pages.requested.last.queryParameters['server'], '1');
    });
  });
}
