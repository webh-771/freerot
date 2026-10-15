// Live shelves smoke test. Skipped unless LIVE=1:
//   LIVE=1 flutter test test/shelves_live_test.dart
//
// Never initialises the Flutter test binding (which would mock HttpClient)
// and resets HttpOverrides, so real HTTP works. Cloudflare sources are not
// verified here, so they are simply skipped by the shelves.
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shortmax_player/data/catalog.dart';
import 'package:shortmax_player/models.dart';

final bool _live = Platform.environment['LIVE'] == '1';
const _skip = 'set LIVE=1 to run live network tests';

String _views(int? v) {
  if (v == null) return '';
  if (v >= 1000000) return ' ${(v / 1000000).toStringAsFixed(1)}M views';
  if (v >= 1000) return ' ${(v / 1000).toStringAsFixed(1)}K views';
  return ' $v views';
}

Future<Paged<Drama>> _show(Catalog cat, String id, {int page = 1}) async {
  final sw = Stopwatch()..start();
  final p = await cat.shelf(id, page);
  final bySource = <String, int>{};
  for (final d in p.items) {
    final l = cat.sourceLabel(d.source);
    bySource[l] = (bySource[l] ?? 0) + 1;
  }
  print('\n== $id page $page: ${p.items.length} items in '
      '${sw.elapsedMilliseconds} ms, hasMore=${p.hasMore}');
  print('   sources: $bySource');
  for (final d in p.items.take(10)) {
    print('   [${cat.sourceLabel(d.source)}] ${d.title}${_views(d.views)}');
  }
  return p;
}

void main() {
  setUpAll(() => HttpOverrides.global = null);
  final cat = Catalog.instance;
  const t = Timeout(Duration(seconds: 120));

  test('most_viewed (cold)', () async {
    final p1 = await _show(cat, 'most_viewed');
    expect(p1.items, isNotEmpty);
    expect(p1.items.every((d) => d.views != null), isTrue);
    final p2 = await _show(cat, 'most_viewed', page: 2);
    expect(p2.items.every((d) => d.views != null), isTrue);
    final again = Stopwatch()..start();
    await cat.shelf('most_viewed', 1);
    print('   cached page 1 again: ${again.elapsedMilliseconds} ms');
  }, skip: _live ? false : _skip, timeout: t);

  test('trending', () async {
    final p = await _show(cat, 'trending');
    expect(p.items, isNotEmpty);
  }, skip: _live ? false : _skip, timeout: t);

  test('new', () async {
    final p = await _show(cat, 'new');
    expect(p.items, isNotEmpty);
    await _show(cat, 'new', page: 2);
  }, skip: _live ? false : _skip, timeout: t);

  test('g:werewolf', () async {
    final p = await _show(cat, 'g:werewolf');
    expect(p.items, isNotEmpty);
    await _show(cat, 'g:werewolf', page: 2);
  }, skip: _live ? false : _skip, timeout: t);

  test('g:billionaire', () async {
    final p = await _show(cat, 'g:billionaire');
    expect(p.items, isNotEmpty);
  }, skip: _live ? false : _skip, timeout: t);

  test('g:dubbed', () async {
    await _show(cat, 'g:dubbed');
  }, skip: _live ? false : _skip, timeout: t);
}
