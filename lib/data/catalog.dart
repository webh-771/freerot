// OWNER: catalog agent. Public signatures are a contract used by UI + player.
// Single entry point for the app: mixes all sources.
import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;

import '../models.dart';
import 'ranking.dart';
import 'shelves.dart';
import 'source.dart';
import 'sources/progressive.dart';
import 'sources/registry.dart';
import 'sources/shelf_hooks.dart';

/// Per-source feed state for the current feed session.
class _FeedState {
  final DramaSource src;
  final int priority;
  int nextPage = 1;
  bool exhausted = false;
  int failures = 0;
  final List<Drama> buffer = [];
  Future<void>? inflight;
  _FeedState(this.src, this.priority);
}

class Catalog {
  Catalog._()
      : _injected = null,
        feedMaxWait = const Duration(seconds: 12),
        feedGrace = const Duration(milliseconds: 1500),
        searchTimeout = const Duration(seconds: 20),
        searchEmitInterval = const Duration(milliseconds: 300),
        shelfFirstWait = const Duration(seconds: 4),
        shelfMaxWait = const Duration(seconds: 40);
  static final Catalog instance = Catalog._();

  /// Catalog over explicit sources (tests).
  @visibleForTesting
  Catalog.withSources(
    List<DramaSource> sources, {
    this.feedMaxWait = const Duration(seconds: 12),
    this.feedGrace = const Duration(milliseconds: 1500),
    this.searchTimeout = const Duration(seconds: 20),
    this.searchEmitInterval = const Duration(milliseconds: 300),
    this.shelfFirstWait = const Duration(seconds: 4),
    this.shelfMaxWait = const Duration(seconds: 40),
  }) : _injected = sources;

  final List<DramaSource>? _injected;

  /// Longest a feed page waits for sources before returning what it has.
  final Duration feedMaxWait;

  /// Once some source has delivered, how long a page keeps waiting for the
  /// others (slow ones are then picked up by a later page).
  final Duration feedGrace;

  /// Per-source search timeout.
  final Duration searchTimeout;

  /// Minimum gap between two search emissions (chunks are coalesced).
  final Duration searchEmitInterval;

  /// A shelf's first page returns after this if it has anything to show.
  final Duration shelfFirstWait;

  /// Longest any shelf page waits for its sources.
  final Duration shelfMaxWait;

  late final List<DramaSource> _sources = List.unmodifiable(
    _injected ?? buildSources(),
  );

  /// Registered sources, highest priority first (used for dedupe ties).
  List<DramaSource> get sources => _sources;

  DramaSource? _sourceFor(String dramaSource) {
    for (final s in _sources) {
      if (s.handles(dramaSource)) return s;
    }
    return null;
  }

  DramaSource _require(String dramaSource) =>
      _sourceFor(dramaSource) ??
      (throw SourceException('No source for "$dramaSource"'));

  int _priority(Drama d) {
    for (var i = 0; i < _sources.length; i++) {
      if (_sources[i].handles(d.source)) return i;
    }
    return _sources.length;
  }

  /// Optional: start fetching feed page 1 of every source (the ShortMax
  /// catalogue takes ~12 s), so the first [feed] call finds it cached.
  ///
  /// Sources with view counts then load their full catalogue in the
  /// background (after their feed page, so the two don't compete), which
  /// makes the "Most viewed" shelf instant later.
  void warmUp() {
    for (final s in _sources) {
      final first = s.feed(1).then((_) => _served.add(s.key), onError: (_) {});
      if (s is ViewCounts) {
        unawaited(first.then(
          (_) => (s as ViewCounts).viewedAll().then((_) {}, onError: (_) {}),
        ));
      } else {
        unawaited(first);
      }
    }
  }

  /// Keys of sources that have answered something this session. A
  /// [SessionGated] (Cloudflare/WebView) source is only used by shelves
  /// once it is in here, so building a shelf never starts a challenge.
  final Set<String> _served = {};

  bool _usable(DramaSource s) => s is! SessionGated || _served.contains(s.key);

  // ------------------------------------------------------------------ feed

  List<_FeedState>? _feedStates;
  final Set<String> _seenKeys = {};
  final Set<String> _seenTitles = {};
  final Map<int, Paged<Drama>> _feedPages = {};
  Future<void> _feedTail = Future.value();

  /// Mixed discovery feed across all sources, page >= 1. Interleaves sources
  /// (weighted), dedupes by normalized title. A failing source is skipped.
  Future<Paged<Drama>> feed(int page) {
    final r = _feedTail.then((_) => _feed(page));
    _feedTail = r.then((_) {}, onError: (_) {});
    return r;
  }

  Future<Paged<Drama>> _feed(int page) async {
    if (page <= 1 || _feedStates == null) {
      _feedStates = [
        for (var i = 0; i < _sources.length; i++) _FeedState(_sources[i], i),
      ];
      _seenKeys.clear();
      _seenTitles.clear();
      _feedPages.clear();
    }
    final cached = _feedPages[page];
    if (cached != null) return cached;
    final states = _feedStates!;

    var items = <Drama>[];
    var hasMore = true;
    // A page can come out empty (all duplicates / sources still loading);
    // try a few rounds before giving up on it.
    for (var round = 0; round < 3 && items.isEmpty && hasMore; round++) {
      for (final s in states) {
        if (!s.exhausted && s.inflight == null && s.buffer.isEmpty) {
          s.inflight = _pull(s).whenComplete(() => s.inflight = null);
        }
      }
      await _awaitSources(states);
      items = _compose(states);
      hasMore = states.any(
        (s) => !s.exhausted || s.buffer.isNotEmpty || s.inflight != null,
      );
    }
    final result = Paged<Drama>(items, hasMore);
    _feedPages[page] = result;
    return result;
  }

  Future<void> _pull(_FeedState s) async {
    try {
      final p = await s.src.feed(s.nextPage);
      _served.add(s.src.key);
      s.nextPage++;
      s.failures = 0;
      s.buffer.addAll(p.items);
      if (!p.hasMore) s.exhausted = true;
    } catch (_) {
      if (++s.failures >= 3) s.exhausted = true;
    }
  }

  /// Wait for in-flight source pages: all of them, or [feedMaxWait], or
  /// [feedGrace] after the first one that brought items (or immediately-ish
  /// if items were already buffered).
  Future<void> _awaitSources(List<_FeedState> states) async {
    final pending = [
      for (final s in states)
        if (s.inflight != null) s.inflight!,
    ];
    if (pending.isEmpty) return;
    final all = Future.wait(pending);
    final done = Completer<void>();
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    Timer? grace;
    void startGrace() => grace ??= Timer(feedGrace, finish);
    if (states.any((s) => s.buffer.isNotEmpty)) startGrace();
    for (final p in pending) {
      p.then((_) {
        if (states.any((s) => s.buffer.isNotEmpty)) startGrace();
      });
    }
    final cap = Timer(feedMaxWait, finish);
    all.then((_) => finish());
    await done.future;
    grace?.cancel();
    cap.cancel();
  }

  /// Weighted round-robin over the buffers (feedWeight items per turn),
  /// skipping anything already shown this session (key or title).
  List<Drama> _compose(List<_FeedState> states) {
    final out = <Drama>[];
    while (states.any((s) => s.buffer.isNotEmpty)) {
      for (final s in states) {
        var taken = 0;
        final w = s.src.feedWeight < 1 ? 1 : s.src.feedWeight;
        while (taken < w && s.buffer.isNotEmpty) {
          final d = s.buffer.removeAt(0);
          if (!_seenKeys.add(d.key)) continue;
          final t = normalizeTitle(d.title);
          if (t.isNotEmpty && !_seenTitles.add(t)) continue;
          out.add(d);
          taken++;
        }
      }
    }
    return out;
  }

  // ---------------------------------------------------------------- search

  /// Unified search over every source in parallel. Emits the full ranked,
  /// deduped list each time another source answers (so fast sources show
  /// first); closes when all sources are done or timed out.
  ///
  /// Sources implementing [ProgressiveSearch] contribute chunk by chunk;
  /// emissions are coalesced to at most one per [searchEmitInterval].
  Stream<List<Drama>> search(String query) {
    final q = query.trim();
    late final StreamController<List<Drama>> ctrl;
    var cancelled = false;
    final found = <Drama>[];
    var dirty = false;
    var emitted = false;
    Timer? pending;
    final sinceEmit = Stopwatch();

    List<String>? lastKeys;

    // Emits the ranked list if it changed. Empty lists are held back until
    // the final emission so the UI doesn't flash "no results".
    void emit({bool last = false}) {
      pending?.cancel();
      pending = null;
      if (cancelled || ctrl.isClosed || !dirty) return;
      dirty = false;
      final ranked = rankResults(q, found, priority: _priority);
      if (ranked.isEmpty && !last) return;
      final keys = [for (final d in ranked) d.key];
      if (lastKeys != null && listEquals(keys, lastKeys)) return;
      lastKeys = keys;
      emitted = true;
      sinceEmit
        ..reset()
        ..start();
      ctrl.add(ranked);
    }

    void addResults(List<Drama> items) {
      if (cancelled) return;
      found.addAll(items);
      dirty = true;
      if (!emitted || sinceEmit.elapsed >= searchEmitInterval) {
        emit();
      } else {
        pending ??= Timer(searchEmitInterval - sinceEmit.elapsed, emit);
      }
    }

    final subs = <StreamSubscription<List<Drama>>>[];

    Future<void> run(DramaSource s) async {
      try {
        await _searchSource(s, q, addResults, subs);
      } catch (_) {
        // a failing / slow source just contributes nothing
      }
    }

    ctrl = StreamController<List<Drama>>(
      onListen: () async {
        if (q.isNotEmpty) await Future.wait([for (final s in _sources) run(s)]);
        if (cancelled) return;
        if (dirty || !emitted) {
          dirty = true;
          emit(last: true);
        }
        await ctrl.close();
      },
      onCancel: () {
        cancelled = true;
        pending?.cancel();
        for (final sub in subs) {
          unawaited(sub.cancel());
        }
      },
    );
    return ctrl.stream;
  }

  /// Search one source, delivering results through [add] (chunk by chunk
  /// for [ProgressiveSearch] sources). Completes when the source is done or
  /// [searchTimeout] passed; throws if a plain source fails. Progressive
  /// subscriptions are added to [subs] so callers can cancel them.
  Future<void> _searchSource(
    DramaSource s,
    String q,
    void Function(List<Drama>) add, [
    List<StreamSubscription<List<Drama>>>? subs,
  ]) async {
    if (s is ProgressiveSearch) {
      // Explicit subscription: never wait on a slow source's cancel.
      final done = Completer<void>();
      void finish() {
        if (!done.isCompleted) done.complete();
      }

      final sub = (s as ProgressiveSearch).searchChunks(q).listen(
            add,
            onError: (Object _) {},
            onDone: finish,
          );
      subs?.add(sub);
      final timer = Timer(searchTimeout, () {
        unawaited(sub.cancel());
        finish();
      });
      await done.future;
      timer.cancel();
    } else {
      add(await s.search(q).timeout(searchTimeout));
    }
    _served.add(s.key);
  }

  // ---------------------------------------------------------- detail/play

  final Map<String, Future<DramaDetail>> _details = {};

  Future<DramaDetail> detail(Drama drama) {
    return _details[drama.key] ??= () async {
      try {
        return await _require(drama.source).detail(drama);
      } catch (_) {
        _details.remove(drama.key);
        rethrow;
      }
    }();
  }

  List<String> servers(DramaDetail detail) =>
      _require(detail.source).servers(detail);

  Future<EpisodeStream> episode(DramaDetail detail, int ep,
          {required String server}) =>
      _require(detail.source).episode(detail, ep, server: server);

  /// "NetShort", "ShortMax", ...
  String sourceLabel(String dramaSource) =>
      _sourceFor(dramaSource)?.label(dramaSource) ?? dramaSource;

  // ---------------------------------------------------------------- shelves
  // OWNER: shelves agent (below). Contract used by the Home filter chips.
  // Definitions, classifier and paging engine: shelves.dart. Optional
  // source capabilities: sources/shelf_hooks.dart.

  /// Filter chips for Home, in display order. First is 'for_you'.
  List<Shelf> get shelves => kShelves;

  final Map<String, ShelfSession> _shelfSessions = {};

  /// A shelf's pages are kept for the session; asking for page 1 again
  /// after this long rebuilds it.
  static const Duration _trendingTtl = Duration(minutes: 5);
  static const Duration _shelfTtl = Duration(minutes: 20);

  /// Items for a shelf, page >= 1. 'for_you' == [feed]. Never throws on
  /// source failures (failing / unverified sources are skipped); an unknown
  /// id gives an empty page.
  Future<Paged<Drama>> shelf(String shelfId, int page) async {
    if (shelfId == 'for_you') return feed(page);
    var session = _shelfSessions[shelfId];
    final ttl = shelfId == 'trending' ? _trendingTtl : _shelfTtl;
    if (session == null ||
        (page <= 1 && DateTime.now().difference(session.created) > ttl)) {
      session = _buildShelf(shelfId);
      if (session == null) return const Paged([], false);
      _shelfSessions[shelfId] = session;
    }
    final result = await session.page(page);
    if (page <= 1 &&
        result.items.isEmpty &&
        identical(_shelfSessions[shelfId], session)) {
      _shelfSessions.remove(shelfId); // nothing came back: retry next time
    }
    return result;
  }

  ShelfSession? _buildShelf(String id) {
    switch (id) {
      case 'most_viewed':
        return _mostViewedShelf();
      case 'trending':
        return _trendingShelf();
      case 'new':
        return _newShelf();
    }
    final g = genreFor(id);
    return g == null ? null : _genreShelf(g);
  }

  ShelfSession _session(
    List<ShelfLane> lanes, {
    ShelfOrder order = ShelfOrder.interleave,
    double Function(Drama)? score,
    bool waitAllAfterFirst = false,
    bool viewsTiebreak = false,
  }) =>
      ShelfSession(
        lanes: lanes,
        order: order,
        score: score,
        waitAllAfterFirst: waitAllAfterFirst,
        viewsTiebreak: viewsTiebreak,
        firstWait: shelfFirstWait,
        maxWait: shelfMaxWait,
      );

  /// Real view counts only ([ViewCounts] sources: ShortMax official
  /// catalogue), highest first. A quick partial list (small official
  /// categories) backs page 1 while the whole catalogue loads.
  ShelfSession _mostViewedShelf() {
    final lanes = <ShelfLane>[];
    for (var i = 0; i < _sources.length; i++) {
      final s = _sources[i];
      if (s is! ViewCounts || !_usable(s)) continue;
      final v = s as ViewCounts;
      final quickDone = Completer<void>();
      lanes
        ..add(ShelfLane(
          name: '${s.key}|quick',
          group: i,
          paged: false,
          fetch: (_, add) async {
            try {
              add(v.viewedCached ?? await v.viewedQuick());
            } finally {
              quickDone.complete();
            }
            return false;
          },
        ))
        ..add(ShelfLane(
          name: '${s.key}|all',
          group: i,
          paged: false,
          fetch: (_, add) async {
            // Let the quick requests go first (the official API slows down
            // under parallel load); a warm-up load already in flight is
            // simply joined.
            if (v.viewedCached == null) {
              await quickDone.future
                  .timeout(const Duration(seconds: 3), onTimeout: () {});
            }
            add(await v.viewedAll());
            _served.add(s.key);
            return false;
          },
        ));
    }
    return _session(
      lanes,
      order: ShelfOrder.views,
      score: (d) => d.views == null ? 0 : 1,
      waitAllAfterFirst: true,
    );
  }

  /// Live "Recently watched" lists of the mirrors ([HistoryFeed]),
  /// round-robin, deduped by title.
  ShelfSession _trendingShelf() {
    final lanes = <ShelfLane>[];
    for (var i = 0; i < _sources.length; i++) {
      final s = _sources[i];
      if (s is! HistoryFeed || !_usable(s)) continue;
      lanes.add(ShelfLane(
        name: '${s.key}|recent',
        group: i,
        fetch: (page, add) async {
          final p = await (s as HistoryFeed).recentlyWatched(page);
          add(p.items);
          _served.add(s.key);
          return p.hasMore;
        },
      ));
    }
    return _session(lanes);
  }

  /// Newest-first listings ([NewestFeed]: ShortMax official default order,
  /// ReelFren netshort/flextv/shorten), interleaved.
  ShelfSession _newShelf() {
    final lanes = <ShelfLane>[];
    for (var i = 0; i < _sources.length; i++) {
      final s = _sources[i];
      if (s is! NewestFeed || !_usable(s)) continue;
      final n = s as NewestFeed;
      for (final lane in n.newestLanes) {
        lanes.add(ShelfLane(
          name: '${s.key}|$lane',
          group: i,
          weight: s.feedWeight,
          fetch: (page, add) async {
            final p = await n.newest(lane, page);
            add(p.items);
            _served.add(s.key);
            return p.hasMore;
          },
        ));
      }
    }
    return _session(lanes);
  }

  /// Genre: every source's search for the genre's strongest keywords,
  /// kept only if the classifier agrees, plus matching official categories
  /// (and the already-loaded official catalogue); mixed across sources.
  ShelfSession _genreShelf(GenreDef g) {
    final lanes = <ShelfLane>[];
    for (var i = 0; i < _sources.length; i++) {
      final s = _sources[i];
      if (!_usable(s)) continue;
      lanes.add(ShelfLane(
        name: '${s.key}|search',
        group: i,
        weight: s.feedWeight,
        paged: false,
        fetch: (_, add) async {
          var ok = 0;
          await Future.wait([
            for (final q in g.search)
              _searchSource(s, q, add).then((_) => ok++, onError: (_) {}),
          ]);
          if (ok == 0) throw SourceException('${s.key}: genre search failed');
          return false;
        },
      ));
      if (s is CategoryListing && g.classes.isNotEmpty) {
        lanes.add(ShelfLane(
          name: '${s.key}|class',
          group: i,
          weight: s.feedWeight,
          paged: false,
          score: (d) => genreScore(g, d, inCategory: true),
          fetch: (_, add) async {
            add(await (s as CategoryListing).categoryItems(
              (name) => g.classes.contains(name.trim().toLowerCase()),
            ));
            return false;
          },
        ));
      }
      final cached = s is ViewCounts ? (s as ViewCounts).viewedCached : null;
      if (cached != null) {
        lanes.add(ShelfLane(
          name: '${s.key}|catalogue',
          group: i,
          weight: s.feedWeight,
          paged: false,
          fetch: (_, add) async {
            add(cached);
            return false;
          },
        ));
      }
    }
    return _session(
      lanes,
      score: (d) => genreScore(g, d),
      viewsTiebreak: true,
    );
  }
}
