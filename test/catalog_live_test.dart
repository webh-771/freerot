// Live multi-source smoke test. Skipped unless LIVE=1:
//   LIVE=1 flutter test test/catalog_live_test.dart
//
// Like live_smoke_test.dart this never initialises the Flutter test binding
// (which would mock HttpClient) and resets HttpOverrides, so real HTTP works.
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shortmax_player/data/catalog.dart';
import 'package:shortmax_player/models.dart';

final bool _live = Platform.environment['LIVE'] == '1';
const _skip = 'set LIVE=1 to run live network tests';
final String _query = Platform.environment['QUERY'] ?? 'ceo';

Future<(int, String)> _probe(String url, bool hls) async {
  final c = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final req = await c.getUrl(Uri.parse(url));
    req.headers.set('Range', 'bytes=0-2047');
    final res = await req.close().timeout(const Duration(seconds: 20));
    final bytes = <int>[];
    await for (final chunk in res) {
      bytes.addAll(chunk);
      if (bytes.length >= 2048) break;
    }
    final head = String.fromCharCodes(bytes.take(16))
        .replaceAll(RegExp(r'[^\x20-\x7e]'), '.');
    return (res.statusCode, head);
  } finally {
    c.close(force: true);
  }
}

void main() {
  setUpAll(() => HttpOverrides.global = null);
  final cat = Catalog.instance;
  List<Drama> lastSearch = const [];

  test('search streams ranked results', () async {
    final sw = Stopwatch()..start();
    final emissions = <(int, int)>[];
    await for (final list in cat.search(_query)) {
      emissions.add((sw.elapsedMilliseconds, list.length));
      lastSearch = list;
    }
    print('search "$_query" emissions (ms, count): $emissions');
    expect(emissions, isNotEmpty);
    expect(lastSearch, isNotEmpty);
    for (final d in lastSearch.take(10)) {
      print('  [${cat.sourceLabel(d.source)}] ${d.title} '
          '(${d.episodes ?? '?'} eps)');
    }
    final sources = lastSearch.map((d) => d.source.split(':').first).toSet();
    print('  sources in results: $sources');
    expect(lastSearch.first.title.toLowerCase(),
        contains(_query.split(' ').first.toLowerCase()));
  }, skip: _live ? false : _skip, timeout: const Timeout(Duration(seconds: 60)));

  test('feed pages mix sources', () async {
    for (var page = 1; page <= 3; page++) {
      final sw = Stopwatch()..start();
      final p = await cat.feed(page);
      final mix = <String, int>{};
      for (final d in p.items) {
        final l = cat.sourceLabel(d.source);
        mix[l] = (mix[l] ?? 0) + 1;
      }
      print('feed($page): ${p.items.length} items in '
          '${sw.elapsedMilliseconds} ms, hasMore=${p.hasMore}, '
          'providers=${mix.length}: $mix');
      expect(p.items, isNotEmpty);
      expect(p.hasMore, isTrue);
      // Consecutive items should mostly come from different providers.
      if (page == 1) {
        var same = 0;
        for (var i = 1; i < p.items.length; i++) {
          if (p.items[i].source == p.items[i - 1].source) same++;
        }
        expect(same, lessThan(p.items.length ~/ 3));
        expect(mix.length, greaterThan(10));
      }
      if (page < 3) {
        // Give the slow ShortMax catalogue time to land for a later page.
        await Future<void>.delayed(const Duration(seconds: 6));
      }
    }
  }, skip: _live ? false : _skip, timeout: const Timeout(Duration(minutes: 2)));

  Future<void> play(Drama d) async {
    final sw = Stopwatch()..start();
    final detail = await cat.detail(d);
    print('detail [${cat.sourceLabel(d.source)}] ${detail.title}: '
        '${detail.totalEpisodes} eps, locked=${detail.locked.length} '
        '(${sw.elapsedMilliseconds} ms)');
    expect(detail.episodes, isNotEmpty);
    final ep = detail.episodes.firstWhere((e) => !detail.locked.contains(e));
    Object? lastError;
    for (final server in cat.servers(detail)) {
      try {
        sw.reset();
        final s = await cat.episode(detail, ep, server: server);
        final (status, head) = await _probe(s.playUrl, s.isHls);
        print('  ep$ep via $server in ${sw.elapsedMilliseconds} ms: '
            'hls=${s.isHls} q=${s.qualities.map((q) => q.label).toList()} '
            'subs=${s.subtitles.length} -> HTTP $status "$head"');
        expect(status, anyOf(200, 206));
        if (s.isHls) expect(head, startsWith('#EXTM3U'));
        return;
      } catch (e) {
        lastError = e;
        print('  $server failed: $e');
      }
    }
    fail('no server played: $lastError');
  }

  test('resolve a ReelFren episode', () async {
    final rf = lastSearch.where((d) => d.source.startsWith('rf:')).toList();
    final pick = rf.firstWhere(
      (d) => d.source == 'rf:netshort' || d.source == 'rf:dramabox',
      orElse: () => rf.first,
    );
    await play(pick);
  }, skip: _live ? false : _skip, timeout: const Timeout(Duration(minutes: 1)));

  test('resolve a ShortMax episode', () async {
    final sm = lastSearch.where((d) => d.source == 'shortmax');
    await play(sm.isNotEmpty
        ? sm.first
        : const Drama(source: 'shortmax', id: '858981', title: '', cover: ''));
  }, skip: _live ? false : _skip, timeout: const Timeout(Duration(minutes: 1)));
}
