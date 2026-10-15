import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shortmax_player/data/library.dart';
import 'package:shortmax_player/models.dart';
import 'package:shortmax_player/ui/home/home_screen.dart';
import 'package:shortmax_player/ui/home/shelf_chips.dart';
import 'package:shortmax_player/ui/theme.dart';
import 'package:shortmax_player/ui/widgets/poster.dart';

const _shelves = [
  Shelf('for_you', 'For you'),
  Shelf('most_viewed', 'Most viewed'),
  Shelf('trending', 'Trending'),
  Shelf('g:werewolf', 'Werewolf'),
  Shelf('g:mafia', 'Mafia'),
];

List<Drama> _dramas(String prefix, int n, {bool views = false}) => [
      for (var i = 0; i < n; i++)
        Drama(
          source: 'fake',
          id: '$prefix$i',
          title: '$prefix $i',
          cover: '', // no network in tests
          views: views ? 1234567 - i : null,
        ),
    ];

/// Scripted shelf data + a call log.
class _Fake {
  final calls = <String>[];
  final data = <String, List<Drama>>{
    'for_you': _dramas('FY', 6),
    'most_viewed': _dramas('MV', 6, views: true),
    'trending': _dramas('TR', 6),
    'g:werewolf': _dramas('WW', 6),
    'g:mafia': const [],
  };
  final failing = <String>{};
  Completer<void>? gate;

  Future<Paged<Drama>> fetch(String id, int page) async {
    calls.add('$id#$page');
    if (gate != null) await gate!.future;
    if (failing.contains(id)) throw Exception('boom');
    return Paged(page == 1 ? data[id] ?? const [] : const [], false);
  }
}

Future<void> _pumpHome(WidgetTester tester, _Fake fake,
    {List<Shelf> Function()? shelves}) async {
  await tester.pumpWidget(MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(
      body: HomeScreen(
        fetcher: fake.fetch,
        shelves: shelves ?? () => _shelves,
      ),
    ),
  ));
  await tester.pump();
  await tester.pump();
}

Future<void> _tapChip(WidgetTester tester, String label) async {
  await tester.tap(find.widgetWithText(ShelfChip, label));
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

bool _selected(WidgetTester tester, String label) =>
    tester.widget<ShelfChip>(find.widgetWithText(ShelfChip, label)).selected;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Library.init();
    HomeScreen.resetSession();
  });

  group('formatCompact / formatViews', () {
    test('compact counts', () {
      expect(formatCompact(0), '0');
      expect(formatCompact(7), '7');
      expect(formatCompact(999), '999');
      expect(formatCompact(1000), '1K');
      expect(formatCompact(1234), '1.2K');
      expect(formatCompact(1299), '1.2K'); // truncates
      expect(formatCompact(12345), '12.3K');
      expect(formatCompact(123456), '123K');
      expect(formatCompact(999999), '999K');
      expect(formatCompact(1000000), '1M');
      expect(formatCompact(1234567), '1.2M');
      expect(formatCompact(3450000), '3.4M');
      expect(formatCompact(2000000000), '2B');
      expect(formatCompact(-5), '0');
    });

    test('views label', () {
      expect(formatViews(1), '1 view');
      expect(formatViews(999), '999 views');
      expect(formatViews(1234567), '1.2M views');
    });
  });

  group('Home shelves', () {
    testWidgets('chips render; For you loads first', (tester) async {
      final fake = _Fake();
      await _pumpHome(tester, fake);

      for (final s in _shelves) {
        expect(find.widgetWithText(ShelfChip, s.label), findsOneWidget);
      }
      expect(_selected(tester, 'For you'), isTrue);
      expect(fake.calls, ['for_you#1']);
      expect(find.text('FY 0'), findsOneWidget);
      // No view counts outside Most viewed.
      expect(find.textContaining('views'), findsNothing);
    });

    testWidgets('switching chips swaps the grid and caches loaders',
        (tester) async {
      final fake = _Fake();
      await _pumpHome(tester, fake);

      await _tapChip(tester, 'Werewolf');
      expect(_selected(tester, 'Werewolf'), isTrue);
      expect(_selected(tester, 'For you'), isFalse);
      expect(find.text('WW 0'), findsOneWidget);
      expect(find.text('FY 0'), findsNothing);

      await _tapChip(tester, 'Most viewed');
      expect(find.text('MV 0'), findsOneWidget);
      expect(find.text('1.2M views'), findsWidgets);

      // Back to cached shelves: instant, no refetch.
      await _tapChip(tester, 'For you');
      expect(find.text('FY 0'), findsOneWidget);
      await _tapChip(tester, 'Werewolf');
      expect(find.text('WW 0'), findsOneWidget);
      expect(fake.calls, ['for_you#1', 'g:werewolf#1', 'most_viewed#1']);
    });

    testWidgets('placeholders while the first page loads', (tester) async {
      final fake = _Fake();
      await _pumpHome(tester, fake);
      fake.gate = Completer<void>();

      await _tapChip(tester, 'Trending');
      expect(find.byType(PosterPlaceholder), findsWidgets);
      expect(find.text('TR 0'), findsNothing);

      fake.gate!.complete();
      await tester.pump();
      await tester.pump();
      expect(find.byType(PosterPlaceholder), findsNothing);
      expect(find.text('TR 0'), findsOneWidget);
    });

    testWidgets('error state retries; empty state shows message',
        (tester) async {
      final fake = _Fake()..failing.add('trending');
      await _pumpHome(tester, fake);

      await _tapChip(tester, 'Trending');
      expect(find.text('Try again'), findsOneWidget);

      fake.failing.clear();
      await tester.tap(find.text('Try again'));
      await tester.pump();
      await tester.pump();
      expect(find.text('TR 0'), findsOneWidget);
      expect(fake.calls.where((c) => c == 'trending#1').length, 2);

      await _tapChip(tester, 'Mafia');
      expect(find.text('No shows in Mafia yet.'), findsOneWidget);
      await tester.tap(find.text('Refresh'));
      await tester.pump();
      await tester.pump();
      expect(fake.calls.where((c) => c == 'g:mafia#1').length, 2);
    });

    testWidgets('switching scrolls to the chip bar, restores per-shelf depth',
        (tester) async {
      final fake = _Fake()
        ..data['for_you'] = _dramas('FY', 60)
        ..data['g:werewolf'] = _dramas('WW', 60);
      await _pumpHome(tester, fake);
      ScrollPosition pos() =>
          tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      // App bar (56) + 4px gap: where the chip bar pins.
      const anchor = kToolbarHeight + 4;

      pos().jumpTo(1500);
      await tester.pump();
      await _tapChip(tester, 'Werewolf');
      expect(pos().pixels, anchor);

      pos().jumpTo(anchor + 700);
      await tester.pump();
      await _tapChip(tester, 'For you');
      expect(pos().pixels, 1500);
      await _tapChip(tester, 'Werewolf');
      expect(pos().pixels, anchor + 700);

      // Above the chip bar: switching leaves the scroll position alone.
      pos().jumpTo(20);
      await tester.pump();
      await _tapChip(tester, 'Trending');
      expect(pos().pixels, 20);
    });

    testWidgets('last chip is remembered for the session', (tester) async {
      final fake = _Fake();
      await _pumpHome(tester, fake);
      await _tapChip(tester, 'Werewolf');

      // Rebuild Home from scratch (same session).
      await tester.pumpWidget(const SizedBox());
      await _pumpHome(tester, fake);
      expect(_selected(tester, 'Werewolf'), isTrue);
      expect(find.text('WW 0'), findsOneWidget);
    });

    testWidgets('falls back to the local chip list when shelves throw',
        (tester) async {
      final fake = _Fake();
      await _pumpHome(tester, fake,
          shelves: () => throw UnimplementedError());
      expect(find.widgetWithText(ShelfChip, 'For you'), findsOneWidget);
      expect(find.widgetWithText(ShelfChip, 'Most viewed'), findsOneWidget);
      expect(find.widgetWithText(ShelfChip, 'Romance'), findsOneWidget);
      expect(fake.calls, ['for_you#1']);
      expect(kFallbackShelves.first.id, kForYouShelf);
      expect(kFallbackShelves.length, 15);
    });
  });
}
