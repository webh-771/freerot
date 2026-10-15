import 'package:flutter/foundation.dart';

import '../../models.dart';

typedef PageFetcher<T> = Future<Paged<T>> Function(int page);

/// Minimal infinite-scroll state holder. Stale responses (after [reset])
/// are dropped via a generation counter.
class PagedLoader<T> extends ChangeNotifier {
  PageFetcher<T> _fetch;
  final String Function(T)? keyOf;

  PagedLoader(this._fetch, {this.keyOf});

  final List<T> items = [];
  final Set<String> _keys = {};
  int _nextPage = 1;
  bool hasMore = true;
  bool loading = false;
  Object? error;
  int _gen = 0;
  bool _disposed = false;

  /// True before the first page arrives.
  bool get isInitial => items.isEmpty && hasMore && error == null;

  /// Replaces the fetcher (e.g. new query / category) and clears state.
  void reset([PageFetcher<T>? fetch]) {
    if (fetch != null) _fetch = fetch;
    _gen++;
    items.clear();
    _keys.clear();
    _nextPage = 1;
    hasMore = true;
    loading = false;
    error = null;
    _notify();
  }

  /// Clears and loads the first page; completes when it arrives.
  Future<void> refresh([PageFetcher<T>? fetch]) {
    reset(fetch);
    return loadMore();
  }

  Future<void> loadMore() async {
    if (loading || !hasMore) return;
    final gen = _gen;
    loading = true;
    error = null;
    _notify();
    try {
      final page = await _fetch(_nextPage);
      if (gen != _gen || _disposed) return;
      var added = 0;
      for (final item in page.items) {
        final k = keyOf?.call(item);
        if (k != null && !_keys.add(k)) continue;
        items.add(item);
        added++;
      }
      _nextPage++;
      // Guard against endpoints that claim more but return nothing new.
      hasMore = page.hasMore && added > 0;
    } catch (e) {
      if (gen != _gen || _disposed) return;
      error = e;
    } finally {
      if (gen == _gen && !_disposed) {
        loading = false;
        _notify();
      }
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
