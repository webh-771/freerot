import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shortmax_player/data/library.dart';
import 'package:shortmax_player/models.dart';

Drama _d(String id, {int? episodes = 60, String source = 'shortmax'}) => Drama(
    source: source,
    id: id,
    title: 'Drama $id',
    cover: 'https://x/$id.jpg',
    episodes: episodes);

/// Key of a ShortMax drama with [id] (default source in [_d]).
String _k(String id) => 'shortmax:$id';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final lib = Library.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Library.init();
  });

  tearDown(() => lib.flush());

  group('continue watching', () {
    test('most recent first, one entry per drama', () async {
      await lib.saveProgress(_d('a'), 1, 1000, 60000);
      await lib.saveProgress(_d('b'), 2, 2000, 60000);
      await lib.saveProgress(_d('c'), 3, 3000, 60000);
      expect(lib.continueWatching.map((p) => p.drama.id), ['c', 'b', 'a']);

      await lib.saveProgress(_d('a'), 4, 5000, 60000);
      expect(lib.continueWatching.map((p) => p.drama.id), ['a', 'c', 'b']);
      final a = lib.progressFor(_k('a'))!;
      expect(a.ep, 4);
      expect(a.positionMs, 5000);
      expect(a.durationMs, 60000);
      expect(lib.progressFor(_k('zzz')), isNull);
    });

    test('capped at 50, oldest dropped', () async {
      for (var i = 0; i < 60; i++) {
        await lib.saveProgress(_d('d$i'), 1, i, 60000);
      }
      expect(lib.continueWatching.length, Library.maxProgress);
      expect(lib.continueWatching.first.drama.id, 'd59');
      expect(lib.continueWatching.last.drama.id, 'd10');
      expect(lib.progressFor(_k('d9')), isNull);
    });

    test('finished episode advances to next; last episode kept', () async {
      await lib.saveProgress(_d('a', episodes: 10), 3, 59000, 60000);
      var p = lib.progressFor(_k('a'))!;
      expect(p.ep, 4);
      expect(p.positionMs, 0);

      await lib.saveProgress(_d('a', episodes: 10), 10, 59500, 60000);
      p = lib.progressFor(_k('a'))!;
      expect(p.ep, 10);
      expect(Library.isFinished(p), isTrue);
    });

    test('notifies listeners and persists after flush', () async {
      var calls = 0;
      void listener() => calls++;
      lib.addListener(listener);
      await lib.saveProgress(_d('a'), 2, 1234, 60000);
      lib.removeListener(listener);
      expect(calls, 1);

      await lib.flush();
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('library.progress.v1');
      expect(raw, isNotNull);
      final list = jsonDecode(raw!) as List;
      expect(list.length, 1);

      // Reload from disk.
      await Library.init();
      expect(lib.progressFor(_k('a'))?.positionMs, 1234);
    });

    test('removeProgress', () async {
      await lib.saveProgress(_d('a'), 1, 1, 100);
      await lib.saveProgress(_d('b'), 1, 1, 100);
      await lib.removeProgress(_k('a'));
      expect(lib.continueWatching.map((p) => p.drama.id), ['b']);
      await Library.init();
      expect(lib.continueWatching.map((p) => p.drama.id), ['b']);
    });
  });

  group('my list', () {
    test('toggle adds then removes, persisted in order', () async {
      expect(lib.myList, isEmpty);
      await lib.toggleMyList(_d('a'));
      await lib.toggleMyList(_d('b'));
      expect(lib.inMyList(_k('a')), isTrue);
      expect(lib.myList.map((d) => d.id), ['b', 'a']);

      await Library.init();
      expect(lib.myList.map((d) => d.id), ['b', 'a']);

      await lib.toggleMyList(_d('a'));
      expect(lib.inMyList(_k('a')), isFalse);
      expect(lib.myList.map((d) => d.id), ['b']);

      await Library.init();
      expect(lib.myList.map((d) => d.id), ['b']);
    });
  });

  group('multi-source identity', () {
    test('same id on different sources are separate entries', () async {
      await lib.saveProgress(_d('1', source: 'shortmax'), 3, 100, 60000);
      await lib.saveProgress(_d('1', source: 'dramawave'), 7, 200, 60000);
      expect(lib.continueWatching.map((p) => p.drama.key),
          ['dramawave:1', 'shortmax:1']);
      expect(lib.progressFor('shortmax:1')!.ep, 3);
      expect(lib.progressFor('dramawave:1')!.ep, 7);
      expect(lib.progressFor('1'), isNull);

      await lib.toggleMyList(_d('1', source: 'shortmax'));
      expect(lib.inMyList('shortmax:1'), isTrue);
      expect(lib.inMyList('dramawave:1'), isFalse);

      await lib.removeProgress('dramawave:1');
      expect(lib.continueWatching.map((p) => p.drama.key), ['shortmax:1']);
    });

    test('v1 data (no source field) loads as shortmax', () async {
      // Exactly what v1 of the app wrote: Drama JSON without "source".
      final v1Drama = {
        'id': '42',
        'title': 'Old Drama',
        'cover': 'https://x/42.jpg',
        'episodes': 80,
        'synopsis': 'old',
      };
      SharedPreferences.setMockInitialValues({
        'library.progress.v1': jsonEncode([
          {
            'drama': v1Drama,
            'ep': 5,
            'positionMs': 1500,
            'durationMs': 60000,
            'updatedAt': 1700000000000,
          },
          // Same drama again (older) — deduped on load.
          {
            'drama': v1Drama,
            'ep': 2,
            'positionMs': 10,
            'durationMs': 60000,
            'updatedAt': 1600000000000,
          },
        ]),
        'library.mylist.v1': jsonEncode([v1Drama]),
      });
      await Library.init();

      expect(lib.continueWatching.length, 1);
      final p = lib.progressFor('shortmax:42')!;
      expect(p.drama.source, 'shortmax');
      expect(p.drama.key, 'shortmax:42');
      expect(p.ep, 5);
      expect(p.positionMs, 1500);
      expect(lib.inMyList('shortmax:42'), isTrue);
      expect(lib.myList.single.title, 'Old Drama');

      // Watching it again under the new model updates the same entry.
      await lib.saveProgress(_d('42'), 6, 0, 60000);
      expect(lib.continueWatching.length, 1);
      expect(lib.progressFor('shortmax:42')!.ep, 6);

      // And it re-saves with the source field.
      await lib.flush();
      final prefs = await SharedPreferences.getInstance();
      final saved = jsonDecode(prefs.getString('library.progress.v1')!) as List;
      expect((saved.first as Map)['drama']['source'], 'shortmax');
    });
  });

  group('recent searches', () {
    test('dedupes, most recent first, max 10', () async {
      for (var i = 0; i < 12; i++) {
        await lib.addRecentSearch('q$i');
      }
      await lib.addRecentSearch('Q5');
      expect(lib.recentSearches.length, Library.maxRecentSearches);
      expect(lib.recentSearches.first, 'Q5');
      expect(lib.recentSearches.where((s) => s.toLowerCase() == 'q5').length, 1);
    });
  });
}
