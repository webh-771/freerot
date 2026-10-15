import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/catalog.dart';
import '../../data/library.dart';
import '../../models.dart';
import '../verify/verify_banner.dart';
import '../nav.dart';
import '../theme.dart';
import '../widgets/poster.dart';
import '../widgets/states.dart';

class SearchScreen extends StatefulWidget {
  /// Owned by the shell so it can focus the field when the tab is opened.
  final FocusNode? focusNode;

  const SearchScreen({super.key, this.focusNode});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen>
    with AutomaticKeepAliveClientMixin {
  static const _debounce = Duration(milliseconds: 500);

  final _controller = TextEditingController();
  final _scroll = ScrollController();
  late final FocusNode _focus = widget.focusNode ?? FocusNode();
  Timer? _timer;
  String _query = '';

  // Streamed results for [_query]: the Catalog emits the full ranked list
  // each time another source answers, then closes.
  StreamSubscription<List<Drama>>? _sub;
  List<Drama> _results = const [];
  Map<String, int> _indexOfKey = const {};
  bool _searching = false;
  Object? _error;

  @override
  bool get wantKeepAlive => true;

  void _onChanged(String text) {
    _timer?.cancel();
    final q = text.trim();
    if (q.isEmpty) {
      _cancelSearch();
      setState(() {
        _query = '';
        _setResults(const []);
        _error = null;
      });
      return;
    }
    _timer = Timer(_debounce, () => _run(q, remember: false));
  }

  void _run(String q, {bool remember = true, bool force = false}) {
    _timer?.cancel();
    q = q.trim();
    if (q.isEmpty) return;
    if (_controller.text.trim() != q) {
      _controller.value = TextEditingValue(
        text: q,
        selection: TextSelection.collapsed(offset: q.length),
      );
    }
    if (remember) Library.instance.addRecentSearch(q);
    if (!force &&
        q == _query &&
        (_results.isNotEmpty || _searching) &&
        _error == null) {
      return;
    }
    _start(q);
  }

  void _start(String q) {
    _cancelSearch();
    if (_scroll.hasClients) _scroll.jumpTo(0);
    setState(() {
      _query = q;
      _setResults(const []);
      _error = null;
      _searching = true;
    });
    Stream<List<Drama>> stream;
    try {
      stream = Catalog.instance.search(q);
    } catch (e) {
      setState(() {
        _searching = false;
        _error = e;
      });
      return;
    }
    late final StreamSubscription<List<Drama>> sub;
    bool live() => mounted && identical(_sub, sub);
    sub = stream.listen(
      (list) {
        if (!live()) return;
        setState(() => _setResults(list));
      },
      onError: (Object e) {
        // One source failing is normal; only surface it if nothing came back.
        if (!live()) return;
        debugPrint('[search] $e');
        if (_results.isEmpty) _error = e;
      },
      onDone: () {
        if (!live()) return;
        setState(() {
          _searching = false;
          _sub = null;
        });
      },
      cancelOnError: false,
    );
    _sub = sub;
  }

  void _cancelSearch() {
    _sub?.cancel();
    _sub = null;
    _searching = false;
  }

  /// Replaces the result list, dropping duplicate keys (first wins).
  void _setResults(List<Drama> list) {
    final seen = <String, int>{};
    final out = <Drama>[];
    for (final d in list) {
      if (seen.containsKey(d.key)) continue;
      seen[d.key] = out.length;
      out.add(d);
    }
    _results = out;
    _indexOfKey = seen;
    // A late non-empty emission supersedes an earlier error.
    if (out.isNotEmpty) _error = null;
  }

  void _clear() {
    _controller.clear();
    _onChanged('');
    _focus.requestFocus();
  }

  bool _onScroll(ScrollNotification n) {
    if (n is ScrollStartNotification &&
        n.dragDetails != null &&
        _focus.hasFocus) {
      _focus.unfocus();
    }
    return false;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sub?.cancel();
    _controller.dispose();
    _scroll.dispose();
    if (widget.focusNode == null) _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: ListenableBuilder(
              listenable: _controller,
              builder: (context, _) => TextField(
                controller: _controller,
                focusNode: _focus,
                onChanged: _onChanged,
                onSubmitted: (q) => _run(q),
                textInputAction: TextInputAction.search,
                cursorColor: AppColors.accent,
                style: const TextStyle(fontSize: 16),
                decoration: InputDecoration(
                  hintText: 'Search dramas',
                  prefixIcon: const Icon(Icons.search_rounded,
                      color: AppColors.textMuted),
                  suffixIcon: _controller.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close_rounded,
                              color: AppColors.textMuted),
                          onPressed: _clear,
                        ),
                ),
              ),
            ),
          ),
          VerifyBanner(
            onVerified: () {
              if (_query.isNotEmpty) _run(_query, remember: false, force: true);
            },
          ),
          // Thin progress line while sources are still answering.
          SizedBox(
            height: 2,
            child: _query.isNotEmpty && _searching
                ? const LinearProgressIndicator(
                    minHeight: 2,
                    backgroundColor: Colors.transparent,
                  )
                : null,
          ),
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScroll,
              child: _query.isEmpty ? _recent() : _resultsView(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _recent() {
    return ListenableBuilder(
      listenable: Library.instance,
      builder: (context, _) {
        final recent = Library.instance.recentSearches;
        if (recent.isEmpty) {
          return const EmptyView(
            icon: Icons.search_rounded,
            message: 'Find a drama by title.',
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            Row(
              children: [
                Text('Recent',
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                TextButton(
                  onPressed: Library.instance.clearRecentSearches,
                  style: TextButton.styleFrom(
                      foregroundColor: AppColors.textMuted),
                  child: const Text('Clear'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final q in recent)
                  InputChip(
                    label: Text(q),
                    onPressed: () {
                      _focus.unfocus();
                      _run(q);
                    },
                    onDeleted: () => Library.instance.removeRecentSearch(q),
                    deleteIcon: const Icon(Icons.close_rounded, size: 16),
                    deleteIconColor: AppColors.textFaint,
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _resultsView() {
    final items = _results;
    if (items.isEmpty && !_searching) {
      if (_error != null) {
        return ErrorView(
            error: _error, onRetry: () => _run(_query, force: true));
      }
      return EmptyView(message: 'No results for "$_query".');
    }
    final footer = posterFooterExtent(context, subtitle: true);
    final showPlaceholders = items.isEmpty;
    return CustomScrollView(
      controller: _scroll,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          sliver: SliverGrid(
            gridDelegate: PosterGridDelegate(footerExtent: footer),
            delegate: SliverChildBuilderDelegate(
              (context, i) {
                if (showPlaceholders) return const PosterPlaceholder();
                final d = items[i];
                return Poster(
                  key: ValueKey(d.key),
                  drama: d,
                  subtitle: _subtitle(d),
                  onTap: () {
                    Library.instance.addRecentSearch(_query);
                    openDetail(context, d);
                  },
                );
              },
              childCount: showPlaceholders ? 9 : items.length,
              // Keep poster state (loaded images) when the list re-ranks.
              findChildIndexCallback: showPlaceholders
                  ? null
                  : (key) => key is ValueKey<String>
                      ? _indexOfKey[key.value]
                      : null,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: SizedBox(height: 24 + MediaQuery.paddingOf(context).bottom),
        ),
      ],
    );
  }

  /// "NetShort · 60 eps" (either part may be missing).
  static String? _subtitle(Drama d) {
    final parts = [
      sourceName(d.source),
      if (d.episodes != null && d.episodes! > 0) '${d.episodes} eps',
    ].where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? null : parts.join(' · ');
  }
}
