import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../data/library.dart';
import '../../models.dart';
import '../verify/verify_banner.dart';
import '../nav.dart';
import '../theme.dart';
import '../widgets/paged.dart';
import '../widgets/poster.dart';
import '../widgets/states.dart';
import 'shelf_chips.dart';

const _hPad = 16.0;

class HomeScreen extends StatefulWidget {
  /// Loads shelf pages; defaults to the catalog (tests inject a fake).
  final ShelfFetcher? fetcher;

  /// Supplies the chip list; defaults to the catalog's shelves. If it throws
  /// or returns nothing, [kFallbackShelves] is used.
  final List<Shelf> Function()? shelves;

  const HomeScreen({super.key, this.fetcher, this.shelves});

  /// Last selected chip — remembered for this app session only.
  static String? _sessionShelf;

  @visibleForTesting
  static void resetSession() => _sessionShelf = null;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with AutomaticKeepAliveClientMixin {
  final _scroll = ScrollController();
  final _chipsKey = GlobalKey();
  late final List<Shelf> _shelves = _loadShelves();
  late String _current;

  /// One loader per visited shelf, kept for the session so switching back
  /// is instant.
  final Map<String, PagedLoader<Drama>> _loaders = {};

  /// Per shelf: how far below the chip bar the user had scrolled.
  final Map<String, double> _depth = {};

  PagedLoader<Drama> get _grid => _loaders[_current]!;

  ShelfFetcher get _fetch => widget.fetcher ?? catalogShelfFetcher;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    final last = HomeScreen._sessionShelf;
    _current = _shelves.any((s) => s.id == last) ? last! : _shelves.first.id;
    _loaderFor(_current);
  }

  List<Shelf> _loadShelves() {
    try {
      final list = (widget.shelves ?? catalogShelves)();
      if (list.isNotEmpty) return list;
    } catch (_) {
      // fall back below
    }
    return kFallbackShelves;
  }

  PagedLoader<Drama> _loaderFor(String id) {
    final existing = _loaders[id];
    if (existing != null) return existing;
    final loader = PagedLoader<Drama>((p) => _fetch(id, p), keyOf: (d) => d.key)
      ..addListener(() => _onGrid(id));
    _loaders[id] = loader;
    loader.loadMore();
    return loader;
  }

  void _onGrid(String id) {
    if (!mounted || id != _current) return;
    setState(() {});
    // If a page doesn't fill the viewport, no scroll event will ask for more.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || id != _current || !_scroll.hasClients) return;
      if (_grid.hasMore &&
          !_grid.loading &&
          _grid.error == null &&
          _grid.items.isNotEmpty &&
          _scroll.position.extentAfter < 800) {
        _grid.loadMore();
      }
    });
  }

  /// Scroll offset at which the chip bar reaches the top and pins.
  double _anchor() {
    final ro = _chipsKey.currentContext?.findRenderObject();
    if (ro is! RenderSliver) return 0;
    try {
      return ro.constraints.precedingScrollExtent;
    } catch (_) {
      return 0; // not laid out yet
    }
  }

  void _select(String id) {
    final hasClients = _scroll.hasClients;
    final anchor = hasClients ? _anchor() : 0.0;
    final off = hasClients ? _scroll.offset : 0.0;
    final below = off > anchor + 0.5;

    if (id == _current) {
      // Tapping the active chip returns to the start of its grid.
      if (below) {
        _scroll.animateTo(anchor,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic);
      }
      return;
    }

    if (below) {
      _depth[_current] = off - anchor;
    } else {
      _depth.remove(_current);
    }
    // Below the chip bar: land at the new shelf's remembered spot (or its
    // start). Above it: stay put.
    final target = below ? anchor + (_depth[id] ?? 0) : off;
    // Moving up is valid against the current content, so do it before the
    // swap — avoids a frame of the old offset clamped against new content.
    if (hasClients && target < off) _scroll.jumpTo(target);

    setState(() {
      _current = id;
      HomeScreen._sessionShelf = id;
    });
    final loader = _loaderFor(id);
    if (loader.isInitial && !loader.loading) loader.loadMore();

    if (hasClients && target > off) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients || _current != id) return;
        _scroll.jumpTo(math.min(target, _scroll.position.maxScrollExtent));
      });
    }
  }

  /// Pull-to-refresh: reload the current shelf from page 1.
  Future<void> _refresh() => _grid.refresh();

  /// After a Cloudflare check: reload the current shelf, drop the others so
  /// they refetch when opened.
  void _reloadAll() {
    for (final id in _loaders.keys.toList()) {
      if (id == _current) continue;
      _loaders.remove(id)!.dispose();
      _depth.remove(id);
    }
    _grid.refresh();
  }

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis == Axis.vertical &&
        n.metrics.extentAfter < 800 &&
        _grid.error == null) {
      _grid.loadMore();
    }
    return false;
  }

  @override
  void dispose() {
    for (final l in _loaders.values) {
      l.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // The status bar gets a solid strip so the pinned chip bar never slides
    // under the system icons once the app bar floats away.
    final topInset = MediaQuery.paddingOf(context).top;
    return ColoredBox(
      color: AppColors.background,
      child: Padding(
        padding: EdgeInsets.only(top: topInset),
        child: MediaQuery.removePadding(
          context: context,
          removeTop: true,
          child: RefreshIndicator(
            onRefresh: _refresh,
            color: AppColors.accent,
            backgroundColor: AppColors.surface,
            edgeOffset: kToolbarHeight,
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScroll,
              child: CustomScrollView(
                controller: _scroll,
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  const SliverAppBar(
                    primary: false,
                    floating: true,
                    snap: true,
                    titleSpacing: _hPad,
                    title: Wordmark(),
                  ),
                  SliverToBoxAdapter(
                    child: ListenableBuilder(
                      listenable: Library.instance,
                      builder: (context, _) => _ContinueRow(
                          items: Library.instance.continueWatching),
                    ),
                  ),
                  SliverToBoxAdapter(
                      child: VerifyBanner(onVerified: _reloadAll)),
                  const SliverToBoxAdapter(child: SizedBox(height: 4)),
                  SliverPersistentHeader(
                    key: _chipsKey,
                    pinned: true,
                    delegate: ShelfBarDelegate(
                      shelves: _shelves,
                      selected: _current,
                      onSelected: _select,
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 8)),
                  ..._gridSlivers(),
                  // Bottom breathing room, stretched when the shelf is short
                  // so the chip bar can always pin at the top.
                  SliverLayoutBuilder(builder: (context, c) {
                    final bottom = 24 + MediaQuery.paddingOf(context).bottom;
                    final below = c.precedingScrollExtent - _anchor();
                    final need = c.viewportMainAxisExtent - below;
                    return SliverToBoxAdapter(
                      child: SizedBox(height: math.max(bottom, need)),
                    );
                  }),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String get _label {
    for (final s in _shelves) {
      if (s.id == _current) return s.label;
    }
    return '';
  }

  List<Widget> _gridSlivers() {
    final grid = _grid;
    final showViews = _current == kMostViewedShelf;
    final delegate = PosterGridDelegate(
      footerExtent: posterFooterExtent(context, subtitle: showViews),
    );
    if (grid.items.isEmpty) {
      if (grid.error != null) {
        return [
          SliverToBoxAdapter(
            key: ValueKey('error:$_current'),
            child: ErrorView(error: grid.error, onRetry: grid.loadMore),
          ),
        ];
      }
      if (!grid.hasMore) {
        return [
          SliverToBoxAdapter(
            key: ValueKey('empty:$_current'),
            child: EmptyView(
              message: _current == kForYouShelf
                  ? 'Nothing here yet.'
                  : 'No shows in $_label yet.',
              onRetry: grid.refresh,
            ),
          ),
        ];
      }
      return [
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: _hPad),
          sliver: SliverGrid(
            gridDelegate: delegate,
            delegate: SliverChildBuilderDelegate(
              (_, _) => const PosterPlaceholder(),
              childCount: 12,
            ),
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        key: ValueKey('grid:$_current'),
        padding: const EdgeInsets.symmetric(horizontal: _hPad),
        sliver: SliverGrid(
          gridDelegate: delegate,
          delegate: SliverChildBuilderDelegate(
            (context, i) {
              final d = grid.items[i];
              final views = d.views;
              return Poster(
                key: ValueKey(d.key),
                drama: d,
                subtitle:
                    showViews && views != null ? formatViews(views) : null,
                onTap: () => openDetail(context, d),
              );
            },
            childCount: grid.items.length,
          ),
        ),
      ),
      SliverToBoxAdapter(
        child: grid.error != null
            ? ErrorView(error: grid.error, onRetry: grid.loadMore, compact: true)
            : grid.hasMore
                ? const LoadingFooter()
                : const SizedBox(height: 16),
      ),
    ];
  }
}

/// "FreeRot" wordmark with optional logo.
class Wordmark extends StatelessWidget {
  const Wordmark({super.key});

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.8,
      height: 1,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset(
          'assets/logo.png',
          width: 26,
          height: 26,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
        const SizedBox(width: 8),
        const Text.rich(
          TextSpan(children: [
            TextSpan(text: 'Free', style: TextStyle(color: AppColors.text)),
            TextSpan(text: 'Rot', style: TextStyle(color: AppColors.accent)),
          ]),
          style: style,
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(_hPad, 20, _hPad, 12),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );
}

class _ContinueRow extends StatelessWidget {
  final List<WatchProgress> items;
  const _ContinueRow({required this.items});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    const width = 112.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle('Continue watching'),
        SizedBox(
          height: width * 4 / 3 + posterFooterExtent(context),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: _hPad),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, i) {
              final p = items[i];
              return SizedBox(
                width: width,
                child: Poster(
                  key: ValueKey(p.drama.key),
                  drama: p.drama,
                  progress: p.fraction,
                  badge: 'EP ${p.ep}',
                  onTap: () => resumeProgress(context, p),
                  onLongPress: () => confirmRemoveProgress(context, p),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
