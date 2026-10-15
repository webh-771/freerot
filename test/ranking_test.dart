import 'package:flutter_test/flutter_test.dart';
import 'package:shortmax_player/data/ranking.dart';
import 'package:shortmax_player/models.dart';

Drama d(
  String title, {
  String source = 'rf:netshort',
  String? id,
  int? eps,
  String? synopsis,
  String cover = 'c',
}) =>
    Drama(
      source: source,
      id: id ?? title,
      title: title,
      cover: cover,
      episodes: eps,
      synopsis: synopsis,
    );

int prio(Drama x) => x.source == 'shortmax' ? 0 : 1;

void main() {
  group('normalizeTitle', () {
    test('case, punctuation, whitespace', () {
      expect(normalizeTitle('  The CEO\'s   Runaway-Bride!! '),
          'the ceo runaway bride');
      expect(normalizeTitle('Boss Up, My CEO!'), 'boss up my ceo');
    });
    test('diacritics', () {
      expect(normalizeTitle('Café Amélie Señor'), 'cafe amelie senor');
      expect(normalizeTitle('Straße'), 'strasse');
    });
    test('curly apostrophes and possessives', () {
      expect(normalizeTitle('Stealing the Cold-Blooded CEO’s Heart'),
          'stealing the cold blooded ceo heart');
      expect(normalizeTitle("Don't Leave"), 'dont leave');
    });
    test('dub/sub tags stripped', () {
      expect(normalizeTitle('Fated Hearts [Dubbed]'), 'fated hearts');
      expect(normalizeTitle('Fated Hearts (Eng Dub)'), 'fated hearts');
      expect(normalizeTitle('Fated Hearts (English Dubbed)'), 'fated hearts');
      expect(normalizeTitle('Fated Hearts eng dub'), 'fated hearts');
      expect(normalizeTitle('Fated Hearts - English Sub'), 'fated hearts');
      expect(normalizeTitle('【Dubbed】Fated Hearts'), 'fated hearts');
    });
    test('meaningful brackets kept', () {
      expect(normalizeTitle('Love (Again)'), 'love again');
      expect(normalizeTitle('Yu☆Gi☆Oh! Arc-V'), 'yu gi oh arc v');
    });
    test('non-latin preserved', () {
      expect(normalizeTitle('CEO와 번개혼'), 'ceo와 번개혼');
    });
  });

  group('score tiers', () {
    const q = 'ceo wife';
    test('exact > prefix > all words > substring > partial', () {
      final exact = score(q, "CEO's Wife");
      final prefix = score(q, 'CEO Wife Returns');
      final allWords = score(q, "The Wife of the CEO");
      final phrase = score(q, 'My Secret CEO Wife Is Back Again');
      final partial = score(q, 'The Runaway Wife Story Of A Lifetime');
      expect(exact, 1.0);
      expect(prefix, 0.9);
      expect(allWords, lessThan(prefix));
      expect(allWords, greaterThanOrEqualTo(0.6));
      expect(phrase, greaterThanOrEqualTo(0.75));
      // Half the words: kept, but below every stronger tier.
      expect(partial, greaterThanOrEqualTo(kMinScore));
      expect(partial, lessThan(0.45));
      // A third of the words: dropped.
      expect(score('ceo secret wife', 'The Runaway Wife Story'),
          lessThan(kMinScore));
      expect(score(q, 'Nothing In Common'), 0);
    });
    test('substring tier for non-word-aligned match', () {
      final s = score('love', 'Glovebox Mystery');
      expect(s, greaterThanOrEqualTo(0.45));
      expect(s, lessThan(0.6));
      // Glued non-latin suffix still counts as the word.
      expect(score('ceo', 'CEO와 번개혼'), greaterThanOrEqualTo(0.45));
    });
    test('shorter title with all words ranks above longer one', () {
      expect(score('mafia king', 'The Mafia King'),
          greaterThan(score('mafia king', 'Dumped the Cheat, I Slept with the Mafia King Tonight')));
    });
    test('stop words ignored for word matching', () {
      expect(score('the billionaire', 'Billionaire Daddy'),
          greaterThanOrEqualTo(0.6));
    });
    test('word-start is weaker than a whole word; plurals are whole words',
        () {
      final plural = score('alpha', 'One Night With Three Alphas');
      final wordStart = score('alpha', 'The Alphabet Murders');
      expect(plural, greaterThanOrEqualTo(0.6));
      expect(wordStart, greaterThanOrEqualTo(kMinScore));
      expect(wordStart, lessThan(plural));
      expect(score('alphas', 'The Alpha King'), greaterThanOrEqualTo(0.6));
      expect(score('mafia kin', 'The Mafia King'),
          inInclusiveRange(kMinScore, 0.6));
    });
    test('tags ignored when matching', () {
      expect(score('fated hearts', 'Fated Hearts (Eng Dub)'), 1.0);
    });
    test('empty', () {
      expect(score('', 'x'), 0);
      expect(score('x', ''), 0);
    });
  });

  group('rankScore boosts', () {
    test('ascii title preferred for ascii query; episodes boost', () {
      final en = rankScore('ceo', d('Boss Up, My CEO!', eps: 40));
      final noEps = rankScore('ceo', d('Boss Up, My CEO!'));
      final ko = rankScore('ceo', d('CEO와 번개혼'));
      expect(en, greaterThan(noEps));
      expect(noEps, greaterThan(ko));
    });
  });

  group('dedupe', () {
    test('by key', () {
      final out = dedupe([d('A', id: '1'), d('A', id: '1')], priority: prio);
      expect(out.length, 1);
    });
    test('by normalized title, higher-priority source wins in place', () {
      final out = dedupe([
        d('The CEO’s Wife', id: 'rf1', eps: 60, synopsis: 'long text here'),
        d('Other', id: 'o'),
        d("The CEO's Wife [Dubbed]", source: 'shortmax', id: 'sm1'),
      ], priority: prio);
      expect(out.map((e) => e.key), ['shortmax:sm1', 'rf:netshort:o']);
    });
    test('same priority keeps richer entry', () {
      final out = dedupe([
        d('Love Rekindled', source: 'rf:netshort', id: '1',
            synopsis: 'NetShort drama'),
        d('Love Rekindled', source: 'rf:pinedrama', id: '2', eps: 88,
            synopsis: 'While Ian Shaw was slacking off at work...'),
      ], priority: prio);
      expect(out.single.id, '2');
    });
    test('placeholder intros detected', () {
      expect(isPlaceholderIntro('NetShort drama'), isTrue);
      expect(isPlaceholderIntro('Anamana search result'), isTrue);
      expect(isPlaceholderIntro('After a car crash, Lillian loses her memory'),
          isFalse);
    });
  });

  group('rankResults', () {
    test('orders by relevance, drops weak matches, dedupes', () {
      final items = [
        d('Yu☆Gi☆Oh! Arc-V', id: 'y'),
        d('Take It Off, My CEO Escort', id: 't'),
        d('CEO', id: 'exact-rf'),
        d('CEO', source: 'shortmax', id: 'exact-sm'),
        d('CEO Daddy, Please Don’t Catch Me!', id: 'p'),
        d('CEO와 번개혼', id: 'k'),
        d('My Down-and-Out Husband is a Billionaire', id: 'h'),
      ];
      final out = rankResults('ceo', items, priority: prio);
      expect(out.map((e) => e.id).toList(),
          ['exact-sm', 'p', 't', 'k']);
    });
    test('equal scores interleave sources; priority never orders', () {
      final items = [
        d('Revenge of the Princess', source: 'shortmax', id: 's1', eps: 60),
        d('Revenge RSVP', source: 'shortmax', id: 's2', eps: 30),
        d('Revenge Campus', source: 'shortmax', id: 's3', eps: 40),
        d('Revenge Unleashed', source: 'rf:netshort', id: 'n1', eps: 50),
        d('Revenge Queen', source: 'rf:dramabox', id: 'b1', eps: 70),
        d('Revenge Game', source: 'rf:dramabox', id: 'b2', eps: 70),
        d('Revenge Plan', source: 'idrama', id: 'i1', eps: 20),
      ];
      final out = rankResults('revenge', items, priority: (x) =>
          x.source == 'shortmax' ? 0 : x.source == 'idrama' ? 2 : 1);
      final sources = out.map((e) => e.source).toList();
      expect(out.length, 7);
      // Registry sources alternate (shortmax / reelfren / idrama) and
      // ReelFren's providers alternate inside its turns.
      String group(String s) => s.startsWith('rf:') ? 'rf' : s;
      expect(sources.take(3).map(group).toSet(), {'shortmax', 'rf', 'idrama'});
      expect(sources.sublist(3, 5).map(group).toSet(), {'shortmax', 'rf'});
      final rf = sources.where((s) => s.startsWith('rf:')).toList();
      expect(rf.take(2).toSet().length, 2);
      // A lower-priority source with a better match still ranks first.
      final better = rankResults('revenge', [
        d('Revenge Of The Long Lost Heir', source: 'shortmax', id: 's'),
        d('Revenge', source: 'idrama', id: 'i'),
      ], priority: (x) => x.source == 'shortmax' ? 0 : 1);
      expect(better.first.id, 'i');
    });

    test('richer entries lead within a source', () {
      final out = rankResults('love', [
        d('Love Story', id: 'bare', cover: ''),
        d('Love Match', id: 'rich', eps: 40, synopsis: 'A long real synopsis here'),
      ], priority: prio);
      expect(out.first.id, 'rich');
    });

    test('alpha: matching titles first, unrelated dropped', () {
      final out = rankResults('alpha', [
        d('The Beta Wolf', id: 'beta'),
        d('One Night With Three Alphas', id: 'alphas'),
        d('Alpine Love', id: 'alpine'),
        d('The Alphabet Murders', id: 'alphabet'),
        d("The Alpha's Rejected Mate", id: 'alpha-mate'),
        d('Billionaire Daddy', id: 'daddy'),
      ], priority: prio);
      expect(out.map((e) => e.id), ['alpha-mate', 'alphas', 'alphabet']);
    });

    test('stable for equal scores', () {
      final items = [
        for (var i = 0; i < 20; i++) d('Revenge Story Part $i', id: '$i'),
      ];
      final out = rankResults('revenge story', items, priority: prio);
      // Same length titles -> equal scores -> input order kept.
      expect(out.take(10).map((e) => e.id), [for (var i = 0; i < 10; i++) '$i']);
    });
    test('limit', () {
      final items = [for (var i = 0; i < 50; i++) d('Love $i', id: '$i')];
      expect(rankResults('love', items, priority: prio, limit: 5).length, 5);
    });
  });
}
