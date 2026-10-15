import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shortmax_player/data/source.dart';
import 'package:shortmax_player/data/sources/reelfren_source.dart';
import 'package:shortmax_player/models.dart';

Object? fx(String name) =>
    jsonDecode(File('probes/fixtures/reelfren_$name').readAsStringSync());

const _fallback = Drama(source: 'rf:x', id: '?', title: 'T', cover: 'C');

void main() {
  group('labels + routing', () {
    final src = ReelFrenSource();
    test('handles rf: sources only', () {
      expect(src.handles('rf:netshort'), isTrue);
      expect(src.handles('shortmax'), isFalse);
    });
    test('pretty labels', () {
      expect(src.label('rf:netshort'), 'NetShort');
      expect(src.label('rf:dramabox'), 'DramaBox');
      expect(src.label('rf:iqiyi'), 'iQIYI');
      expect(src.label('rf:flextv2'), 'FlexTV');
      expect(src.label('rf:kalostv'), 'KalosTV');
      expect(src.label('rf:somethingnew'), 'Somethingnew');
    });
    test('excluded providers not in feed list', () {
      expect(src.providers, isNot(contains('filmbox')));
      expect(ReelFrenSource(providers: ['filmbox', 'netshort']).providers,
          ['netshort']);
    });
    test('servers', () {
      expect(
        src.servers(const DramaDetail(
          source: 'rf:netshort', id: '1', title: 't', cover: '',
          synopsis: '', totalEpisodes: 1, episodes: [1],
        )),
        ['1', 'refresh'],
      );
    });
  });

  group('lists', () {
    test('home mixed: excluded providers dropped, rf: source', () {
      final items = parseRfList(fx('home_mixed_page0.json'));
      expect(items.map((d) => d.source),
          ['rf:storyreel', 'rf:pinedrama', 'rf:raptdrama']);
      final s = items.first;
      expect(s.id, '34609');
      expect(s.title, 'THE QUEEN OF THE BLACK EMPIRE');
      expect(s.episodes, 25);
      expect(s.cover, startsWith('https://'));
      expect(s.synopsis, startsWith('He humiliated her'));
      expect(s.key, 'rf:storyreel:34609');
    });
    test('home per provider: episodes 0 -> null', () {
      final items = parseRfList(fx('home_netshort_page1.json'));
      expect(items.length, 4);
      expect(items.every((d) => d.episodes == null), isTrue);
      expect(items.first.source, 'rf:netshort');
    });
    test('search: placeholder intro -> null synopsis, string ids kept', () {
      final items = parseRfList(fx('search_love_page0.json'));
      expect(items.length, 6);
      final anamana = items.firstWhere((d) => d.source == 'rf:anamana');
      expect(anamana.synopsis, isNull);
      expect(anamana.episodes, 30);
      final shorten = items.firstWhere((d) => d.source == 'rf:shorten');
      expect(shorten.id, 'my-divorce-lawyer-is-my-husband');
    });
    test('garbage tolerated', () {
      expect(parseRfList(null), isEmpty);
      expect(parseRfList({'data': [1, {'id': 'x'}]}), isEmpty);
    });
  });

  group('detail', () {
    test('netshort: episodes from max(episodes, videos), nothing locked', () {
      final d = parseRfDetail(fx('detail_netshort.json'), _fallback);
      expect(d.source, 'rf:netshort');
      expect(d.id, '2100522336622321665');
      expect(d.totalEpisodes, 30);
      expect(d.episodes.length, 30);
      expect(d.locked, isEmpty);
      expect(d.synopsis, ''); // "NetShort drama" placeholder
    });
    test('vibeshort placeholders are locked (incl. eps beyond list)', () {
      final d = parseRfDetail(
          fx('detail_vibeshort_placeholders.json'), _fallback);
      expect(d.totalEpisodes, 40);
      expect(d.locked.contains(20), isFalse);
      expect(d.locked.contains(21), isTrue);
      expect(d.locked.contains(23), isTrue);
      expect(d.locked.contains(40), isTrue);
      expect(d.locked.length, 20);
      expect(d.synopsis, startsWith('Sylvia'));
    });
    test('all-placeholder shape on other providers is not locked', () {
      final d = parseRfDetail({
        'id': '9', 'provider': 'blinkdrama', 'title': 'X', 'episodes': 3,
        'videos': [
          for (var i = 1; i <= 3; i++)
            {'episode': i, 'duration': 0, 'vid': '$i', 'available': true},
        ],
      }, _fallback);
      expect(d.locked, isEmpty);
      expect(d.episodes, [1, 2, 3]);
    });
    test('vibeshort with only placeholders is not locked', () {
      final d = parseRfDetail({
        'id': '9', 'provider': 'vibeshort', 'title': 'X', 'episodes': 2,
        'videos': [
          {'episode': 1, 'duration': 0, 'vid': '1'},
          {'episode': 2, 'duration': 0, 'vid': '2'},
        ],
      }, _fallback);
      expect(d.locked, isEmpty);
    });
    test('movie with 0 episodes -> 1', () {
      final d = parseRfDetail(
          {'id': '9', 'provider': 'aniboy', 'title': 'M', 'episodes': 0},
          _fallback);
      expect(d.episodes, [1]);
    });
  });

  group('video', () {
    EpisodeStream parse(String f, String provider) => parseRfVideo(fx(f),
        provider: provider, dramaId: 'id', ep: 1, server: '1');

    test('netshort mp4', () {
      final s = parse('video_netshort_ep1.json', 'netshort');
      expect(s.playUrl, startsWith('https://ns-aws-cdn.netshort.com/'));
      expect(s.isHls, isFalse);
      expect(s.qualities.single.isHls, isFalse);
      expect(s.subtitles, isEmpty);
      expect(s.server, '1');
    });
    test('dramabox qualities best first', () {
      final s = parse('video_dramabox_ep1.json', 'dramabox');
      expect(s.qualities.map((q) => q.label), ['1080p', '720p', '540p']);
      expect(s.isHls, isFalse);
    });
    test('vibeshort hls', () {
      final s = parse('video_vibeshort_ep1.json', 'vibeshort');
      expect(s.isHls, isTrue);
      expect(s.qualities.map((q) => q.label), ['1080p', '720p', '480p']);
      expect(s.qualities.every((q) => q.isHls), isTrue);
    });
    test('wetv: relative subtitle urls resolved, English first', () {
      final s = parse('video_wetv_ep1.json', 'wetv');
      expect(s.isHls, isTrue);
      expect(s.subtitles.first.lang, 'en');
      expect(s.subtitles.first.label, 'English');
      for (final sub in s.subtitles) {
        expect(sub.url, startsWith('https://proxy.dramafren.org/api/proxy/'));
      }
    });
    test('/api/subtitle -> api.reelfren.com', () {
      final s = parse('video_filmbox_ep1.json', 'filmbox');
      expect(s.subtitles.first.lang, 'en');
      expect(s.subtitles.first.url,
          startsWith('https://api.reelfren.com/api/subtitle/filmbox?'));
    });
    test('relative video url + missing format detection', () {
      final s = parseRfVideo({
        'locked': false,
        'videoUrl': '/api/proxy/vigloo?url=abc',
        'qualityList': [
          {'label': '540p H.265', 'url': '/api/proxy/vigloo?url=h265'},
          {'label': '540p H.264', 'url': '/api/proxy/vigloo?url=h264'},
          {'label': '720p', 'url': 'https://x/y.m3u8?a=1', 'fallbackUrl': '/api/x'},
          {'label': 'SD', 'url': 'https://x/y.mp4'},
        ],
      }, provider: 'vigloo', dramaId: 'id', ep: 3, server: 'refresh');
      expect(s.playUrl, 'https://proxy.dramafren.org/api/proxy/vigloo?url=abc');
      expect(s.isHls, isTrue); // vigloo = HLS provider
      expect(s.qualities.map((q) => q.label),
          ['720p', '540p H.264', 'SD', '540p H.265']);
      expect(s.qualities.firstWhere((q) => q.label == 'SD').isHls, isFalse);
      expect(s.server, 'refresh');
    });
    test('playUrl falls back to best quality; proxyUrl from fallbackUrl', () {
      final s = parseRfVideo({
        'qualityList': [
          {'label': '720p', 'url': 'https://a/b.m3u8', 'fallbackUrl': '/api/fb'},
        ],
      }, provider: 'x', dramaId: 'id', ep: 1, server: '1');
      expect(s.playUrl, 'https://a/b.m3u8');
      expect(s.proxyUrl, 'https://api.reelfren.com/api/fb');
    });
    test('locked:true -> EpisodeLockedException', () {
      expect(
        () => parseRfVideo({'locked': true}, provider: 'x', dramaId: 'i',
            ep: 1, server: '1'),
        throwsA(isA<EpisodeLockedException>()),
      );
    });
    test('no url -> SourceException (not locked)', () {
      expect(
        () => parseRfVideo({'locked': false, 'qualityList': []},
            provider: 'x', dramaId: 'i', ep: 1, server: '1'),
        throwsA(allOf(isA<SourceException>(),
            isNot(isA<EpisodeLockedException>()))),
      );
    });
    test('rfAbsUrl', () {
      expect(rfAbsUrl('/api/proxy/a'), 'https://proxy.dramafren.org/api/proxy/a');
      expect(rfAbsUrl('/api/subtitle/a'), 'https://api.reelfren.com/api/subtitle/a');
      expect(rfAbsUrl('https://x/y'), 'https://x/y');
      expect(rfAbsUrl(null), '');
    });
  });
}
