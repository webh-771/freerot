// OWNER: UI agent. Public signatures are a contract used by the player.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';

/// Local persistence: continue watching + My List. Call [Library.init] in main().
class Library extends ChangeNotifier {
  Library._();
  static final Library instance = Library._();

  static const _kProgress = 'library.progress.v1';
  static const _kMyList = 'library.mylist.v1';
  static const _kRecentSearches = 'library.recentSearches.v1';

  /// Max entries kept in continue watching.
  static const int maxProgress = 50;

  /// Max recent search queries kept.
  static const int maxRecentSearches = 10;

  /// An episode counts as finished past this fraction of its duration.
  static const double finishedFraction = 0.95;

  /// Delay before progress changes are written to disk.
  static const Duration writeDelay = Duration(seconds: 2);

  SharedPreferences? _prefs;
  List<WatchProgress> _progress = [];
  List<Drama> _myList = [];
  List<String> _recentSearches = [];
  Timer? _writeTimer;
  bool _progressDirty = false;

  static Future<void> init() => instance._load();

  Future<void> _load() async {
    _writeTimer?.cancel();
    _writeTimer = null;
    _progressDirty = false;
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    _progress = _decodeList(prefs.getString(_kProgress), WatchProgress.fromJson);
    _myList = _decodeList(prefs.getString(_kMyList), Drama.fromJson);
    _recentSearches = prefs.getStringList(_kRecentSearches) ?? [];
    // Enforce invariants in case stored data predates them.
    _progress.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final seen = <String>{};
    _progress.retainWhere((p) => seen.add(p.drama.key));
    final seenSaved = <String>{};
    _myList.retainWhere((d) => seenSaved.add(d.key));
    if (_progress.length > maxProgress) {
      _progress = _progress.sublist(0, maxProgress);
    }
    notifyListeners();
  }

  static List<T> _decodeList<T>(
      String? raw, T Function(Map<String, dynamic>) fromJson) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      final out = <T>[];
      for (final e in list) {
        try {
          out.add(fromJson((e as Map).cast<String, dynamic>()));
        } catch (_) {
          // Skip a corrupt entry rather than dropping everything.
        }
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  // ---------------------------------------------------------------------------
  // Continue watching

  /// Most recent first, one entry per drama.
  List<WatchProgress> get continueWatching => List.unmodifiable(_progress);

  /// Progress for the drama with this [Drama.key] (`source:id`).
  WatchProgress? progressFor(String key) {
    for (final p in _progress) {
      if (p.drama.key == key) return p;
    }
    return null;
  }

  /// Called by the player (throttled, ~every 5s + on pause/exit/episode change).
  ///
  /// Cheap: updates memory and notifies immediately; the disk write is
  /// debounced by [writeDelay]. When an episode is finished (>95%) and a next
  /// episode is known to exist, the entry advances to the next episode at 0.
  Future<void> saveProgress(
      Drama drama, int ep, int positionMs, int durationMs) async {
    var e = ep;
    var pos = positionMs < 0 ? 0 : positionMs;
    var dur = durationMs < 0 ? 0 : durationMs;
    final total = drama.episodes;
    if (dur > 0 && pos > dur * finishedFraction && total != null && e < total) {
      e = e + 1;
      pos = 0;
      dur = 0;
    }
    final entry = WatchProgress(
      drama: drama,
      ep: e,
      positionMs: pos,
      durationMs: dur,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _progress.removeWhere((p) => p.drama.key == drama.key);
    _progress.insert(0, entry);
    if (_progress.length > maxProgress) {
      _progress.removeRange(maxProgress, _progress.length);
    }
    notifyListeners();
    _scheduleProgressWrite();
  }

  /// Removes the entry for the drama with this [Drama.key].
  Future<void> removeProgress(String key) async {
    final before = _progress.length;
    _progress.removeWhere((p) => p.drama.key == key);
    if (_progress.length == before) return;
    notifyListeners();
    _progressDirty = true;
    await flush();
  }

  void _scheduleProgressWrite() {
    _progressDirty = true;
    _writeTimer?.cancel();
    _writeTimer = Timer(writeDelay, () {
      _writeTimer = null;
      flush();
    });
  }

  /// Writes any pending progress to disk now (call on app pause/exit).
  Future<void> flush() async {
    _writeTimer?.cancel();
    _writeTimer = null;
    if (!_progressDirty) return;
    _progressDirty = false;
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    await prefs.setString(
        _kProgress, jsonEncode(_progress.map((p) => p.toJson()).toList()));
  }

  /// True when [p] points at a (nearly) finished episode, so resume should
  /// start from the beginning of the next episode / from 0.
  static bool isFinished(WatchProgress p) =>
      p.durationMs > 0 && p.positionMs > p.durationMs * finishedFraction;

  // ---------------------------------------------------------------------------
  // My List

  List<Drama> get myList => List.unmodifiable(_myList);

  /// True if the drama with this [Drama.key] is saved.
  bool inMyList(String key) => _myList.any((d) => d.key == key);

  /// Adds to the front if absent, otherwise removes.
  Future<void> toggleMyList(Drama drama) async {
    final i = _myList.indexWhere((d) => d.key == drama.key);
    if (i >= 0) {
      _myList.removeAt(i);
    } else {
      _myList.insert(0, drama);
    }
    notifyListeners();
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    await prefs.setString(
        _kMyList, jsonEncode(_myList.map((d) => d.toJson()).toList()));
  }

  // ---------------------------------------------------------------------------
  // Recent searches (UI convenience, not part of the player contract)

  List<String> get recentSearches => List.unmodifiable(_recentSearches);

  Future<void> addRecentSearch(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    _recentSearches.removeWhere((s) => s.toLowerCase() == q.toLowerCase());
    _recentSearches.insert(0, q);
    if (_recentSearches.length > maxRecentSearches) {
      _recentSearches.removeRange(maxRecentSearches, _recentSearches.length);
    }
    notifyListeners();
    await _saveRecent();
  }

  Future<void> removeRecentSearch(String query) async {
    _recentSearches.remove(query);
    notifyListeners();
    await _saveRecent();
  }

  Future<void> clearRecentSearches() async {
    _recentSearches.clear();
    notifyListeners();
    await _saveRecent();
  }

  Future<void> _saveRecent() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    await prefs.setStringList(_kRecentSearches, _recentSearches);
  }
}
