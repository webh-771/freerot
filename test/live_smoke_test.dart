// Live network smoke test. Skipped unless LIVE=1:
//   LIVE=1 flutter test test/live_smoke_test.dart
//
// flutter_test's TestWidgetsFlutterBinding replaces HttpClient with a mock
// that always returns 400. We never initialise the binding here, and we also
// reset HttpOverrides so package:http uses the real dart:io HttpClient.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shortmax_player/data/api.dart';

final bool _live = Platform.environment['LIVE'] == '1';

void main() {
  setUpAll(() => HttpOverrides.global = null);
  final api = ShortMaxApi.instance;
  const skip = 'set LIVE=1 to run live network tests';

  test('detail 858981', () async {
    final d = await api.detail('858981');
    expect(d.title, isNotEmpty);
    expect(d.totalEpisodes, greaterThan(0));
    expect(d.episodes, isNotEmpty);
    expect(d.cover, startsWith('https://'));
    // ignore: avoid_print
    print('detail: ${d.title} / ${d.totalEpisodes} eps / ${d.cover}');
  }, skip: _live ? false : skip);

  test('search CEO', () async {
    final p = await api.search('CEO');
    expect(p.items.length, greaterThan(5));
    expect(p.hasMore, isTrue);
    // ignore: avoid_print
    print(
      'search: ${p.items.length} items, first=${p.items.first.title} '
      'eps=${p.items.first.episodes}, hasMore=${p.hasMore}',
    );
  }, skip: _live ? false : skip);

  test('siteRecent', () async {
    final p = await api.siteRecent();
    expect(p.items, isNotEmpty);
    // ignore: avoid_print
    print('recent: ${p.items.length} items, hasMore=${p.hasMore}');
  }, skip: _live ? false : skip);

  test('episode 858981 ep 50 server1', () async {
    final s = await api.episode('858981', 50);
    expect(s.playUrl, contains('.m3u8'));
    expect(s.qualities, isNotEmpty);
    // Verify the m3u8 itself is actually reachable.
    final c = HttpClient();
    final res = await (await c.getUrl(Uri.parse(s.playUrl))).close();
    final body = await res
        .transform(const SystemEncoding().decoder)
        .join()
        .timeout(const Duration(seconds: 15));
    c.close();
    expect(res.statusCode, 200);
    expect(body, startsWith('#EXTM3U'));
    // ignore: avoid_print
    print('episode: ${s.qualities.map((q) => q.label).toList()} ${s.playUrl}');
  }, skip: _live ? false : skip);

  test('browse page 1', () async {
    final p = await api.browse();
    expect(p.items.length, greaterThan(10));
    expect(p.hasMore, isTrue);
    expect(p.items.first.id, matches(RegExp(r'^\d+$')));
    // ignore: avoid_print
    print(
      'browse: ${p.items.length} items, first=${p.items.first.id} '
      '${p.items.first.title}',
    );
  }, skip: _live ? false : skip);

  test('categories + browse by class', () async {
    final c = await api.categories();
    expect(c, isNotEmpty);
    final p = await api.browse(classId: c.first.classId);
    // ignore: avoid_print
    print('categories: ${c.length}, "${c.first.name}" -> ${p.items.length}');
  }, skip: _live ? false : skip);

  test('official id resolves on site', () async {
    final p = await api.browse();
    final d = await api.detail(p.items.first.id);
    expect(d.episodes, isNotEmpty);
  }, skip: _live ? false : skip);
}
