// Live check of the CF-free iDrama source. Skipped unless LIVE=1:
//   LIVE=1 flutter test test/web_idrama_live_test.dart
//
// Like live_smoke_test.dart: no Flutter test binding is initialised and
// HttpOverrides are reset, so package:http talks to the real network.
// (The Cloudflare-protected sources can't be tested live from here: a human
// has to complete the check in the app.)
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shortmax_player/data/sources/idrama_source.dart';

final bool _live = Platform.environment['LIVE'] == '1';

Future<(int, Uint8List)> _fetch(String url) async {
  final c = HttpClient();
  try {
    final req = await c.getUrl(Uri.parse(url));
    req.headers.set('User-Agent', IDramaSource.userAgent);
    final res = await req.close().timeout(const Duration(seconds: 20));
    final bytes = await res
        .fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d))
        .timeout(const Duration(seconds: 30));
    return (res.statusCode, bytes.takeBytes());
  } finally {
    c.close();
  }
}

void main() {
  setUpAll(() => HttpOverrides.global = null);
  const skip = 'set LIVE=1 to run live network tests';

  test('idrama: search -> detail -> episode -> playlist + key', () async {
    final src = IDramaSource();
    final res = await src.search('love');
    expect(res, isNotEmpty);
    final first = res.first;
    expect(first.source, 'idrama');
    // ignore: avoid_print
    print('search: ${res.length} items, first=${first.id} ${first.title} '
        'eps=${first.episodes}');

    final d = await src.detail(first);
    expect(d.totalEpisodes, greaterThan(0));
    expect(d.episodes, isNotEmpty);
    // ignore: avoid_print
    print('detail: ${d.title} / ${d.totalEpisodes} eps / ${d.cover}');

    final s = await src.episode(d, 1, server: src.servers(d).first);
    expect(s.isHls, isTrue);
    // ignore: avoid_print
    print('episode: ${s.playUrl}\n  proxy: ${s.proxyUrl}');

    final (code, body) = await _fetch(s.playUrl);
    expect(code, 200);
    final pl = String.fromCharCodes(body);
    expect(pl, startsWith('#EXTM3U'));
    final key = RegExp(r'#EXT-X-KEY:METHOD=AES-128,URI="([^"]+)"').firstMatch(pl);
    expect(key, isNotNull, reason: 'expected standard HLS AES-128');
    final keyUrl = Uri.parse(s.playUrl).resolve(key!.group(1)!).toString();
    final (kc, kb) = await _fetch(keyUrl);
    expect(kc, 200);
    expect(kb.length, 16);
    final seg = pl
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty && !l.startsWith('#'));
    final (sc, sb) =
        await _fetch(Uri.parse(s.playUrl).resolve(seg).toString());
    expect(sc, 200);
    expect(sb.length, greaterThan(1000));
    // ignore: avoid_print
    print('playlist ok, key ${kb.length}B, first segment ${sb.length}B');

    // Late episode (the mirror labels itself "VIP Unlocked").
    final last = d.episodes.last;
    final ls = await src.episode(d, last, server: src.servers(d).first);
    final (lc, lb) = await _fetch(ls.playUrl);
    expect(lc, 200);
    expect(String.fromCharCodes(lb), startsWith('#EXTM3U'));
    // ignore: avoid_print
    print('late ep $last: playlist ok');
  }, skip: _live ? false : skip, timeout: const Timeout(Duration(minutes: 2)));

  test('idrama: feed page 1', () async {
    final p = await IDramaSource().feed(1);
    expect(p.items, isNotEmpty);
    // ignore: avoid_print
    print('feed: ${p.items.length} items hasMore=${p.hasMore}');
  }, skip: _live ? false : skip);
}
