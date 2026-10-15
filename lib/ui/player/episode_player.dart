// OWNER: player agent.
//
// Per-episode playback holder: resolves the stream, initializes a
// [VideoPlayerController] and walks a fallback chain until one source plays.
//
// Fallback order for an episode (first that initializes wins), for each
// server in Catalog.servers(detail):
//   preferred quality url -> playUrl -> proxyUrl -> remaining qualities
// (deduped, empty skipped). A server is only resolved once every source of
// the previous one failed (unsupported codec, 403, timeout...). The same chain
// is reused (skipping sources that already failed) when a playing stream
// errors mid-way, resuming from the last known position.
//
// EpisodeLockedException from the catalog ends the chain immediately: the
// episode is known-unavailable, so no other server is tried and no retry is
// offered (status == locked).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';

import '../../data/catalog.dart';
import '../../data/source.dart';
import '../../models.dart';

enum EpisodeStatus { idle, loading, ready, error, locked }

int _qualityRank(String label) =>
    int.tryParse(label.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;

/// Picks [preferred] from [qualities]; otherwise the best quality not above
/// it; otherwise the lowest available. Returns null if nothing usable.
@visibleForTesting
VideoQuality? pickQuality(List<VideoQuality> qualities, String preferred) {
  final usable = qualities.where((q) => q.url.isNotEmpty).toList();
  if (usable.isEmpty) return null;
  for (final q in usable) {
    if (q.label == preferred) return q;
  }
  final want = _qualityRank(preferred);
  usable.sort((a, b) => _qualityRank(b.label).compareTo(_qualityRank(a.label)));
  for (final q in usable) {
    if (_qualityRank(q.label) <= want) return q;
  }
  return usable.last;
}

/// Prefers an English track, else the first one. Null if none usable.
@visibleForTesting
Subtitle? pickSubtitle(List<Subtitle> subs) {
  final usable = subs.where((s) => s.url.isNotEmpty).toList();
  if (usable.isEmpty) return null;
  for (final s in usable) {
    final lang = s.lang.toLowerCase();
    if (lang == 'en' || lang.startsWith('en-') || lang.startsWith('en_')) {
      return s;
    }
  }
  for (final s in usable) {
    if (s.label.toLowerCase().contains('english')) return s;
  }
  return usable.first;
}

/// Normalizes a subtitle file for [WebVTTCaptionFile]: strips the BOM, turns
/// SRT-style `00:00:01,000` timestamps into `00:00:01.000`, and removes
/// leading `[...]` junk (sound cues, speaker tags) — a line that is only
/// junk is dropped.
@visibleForTesting
String cleanVtt(String raw) {
  var text = raw.replaceFirst('\uFEFF', '').replaceAll('\r\n', '\n');
  text = text.replaceAllMapped(
      RegExp(r'(\d{1,2}:\d{2}:\d{2}),(\d{3})'), (m) => '${m[1]}.${m[2]}');
  // WebVTT hours need two digits.
  text = text.replaceAllMapped(
      RegExp(r'(^|\s)(\d):(\d{2}:\d{2}\.\d{3})', multiLine: true),
      (m) => '${m[1]}0${m[2]}:${m[3]}');
  final junk = RegExp(r'^\s*\[[^\]]*\]\s*');
  final out = <String>[];
  for (final line in text.split('\n')) {
    if (line.trimLeft().startsWith('[')) {
      var rest = line;
      while (junk.hasMatch(rest)) {
        rest = rest.replaceFirst(junk, '');
      }
      if (rest.trim().isEmpty) continue;
      out.add(rest);
    } else {
      out.add(line);
    }
  }
  return out.join('\n');
}

class _Source {
  final String url;
  final String label;
  final String server;
  final bool isHls;
  final Map<String, String> headers;
  const _Source(this.url, this.label, this.server,
      {required this.isHls, this.headers = const {}});
}

class EpisodeController extends ChangeNotifier {
  EpisodeController({
    required this.detail,
    required this.ep,
    required this._quality,
    this._startAt = Duration.zero,
    this._speed = 1.0,
  });

  static const _resolveTimeout = Duration(seconds: 30);
  static const _initTimeout = Duration(seconds: 20);
  static const _subtitleTimeout = Duration(seconds: 10);

  /// Message shown for a known-unavailable episode.
  static const lockedMessage = "This episode isn't available";

  final DramaDetail detail;
  final int ep;

  String _quality;
  Duration _startAt;
  double _speed;

  EpisodeStatus _status = EpisodeStatus.idle;
  VideoPlayerController? _video;
  _Source? _active;
  String? _error;
  bool _switching = false;

  /// Resolved streams by server, in resolution order.
  final Map<String, EpisodeStream> _streams = {};
  final Set<String> _failedUrls = {};
  bool _lockedHit = false;

  /// Parsed caption files by subtitle URL (null = failed to load).
  final Map<String, Future<ClosedCaptionFile?>> _captions = {};

  bool _wantPlay = false;
  bool _disposed = false;
  int _gen = 0;
  bool _completedFired = false;
  bool _recovering = false;
  Duration _lastPosition = Duration.zero;

  // Snapshot of the video state we forward to listeners (so listeners are
  // not woken on every position tick).
  bool _lastPlaying = false;
  bool _lastBuffering = false;
  bool _lastCompleted = false;

  /// Fired once each time playback reaches the end.
  VoidCallback? onCompleted;

  /// Fired when the catalog reports this episode as unavailable.
  VoidCallback? onLocked;

  EpisodeStatus get status => _status;
  bool get isLocked => _status == EpisodeStatus.locked;
  bool get isReady => _status == EpisodeStatus.ready && _video != null;
  VideoPlayerController? get video => _video;
  String? get error => _error;

  /// True while a quality switch is loading in the background.
  bool get isSwitching => _switching;

  /// Label of the playing source ("720p", or "Auto" if unknown).
  String? get activeQuality => _active?.label;
  String? get activeServer => _active?.server;
  bool get isPlaying => _video?.value.isPlaying ?? false;
  bool get wantsPlay => _wantPlay;

  Duration get position {
    final v = _video?.value;
    if (v == null || v.hasError || !v.isInitialized) return _lastPosition;
    return v.position;
  }

  Duration get duration => _video?.value.duration ?? Duration.zero;

  EpisodeStream? get _activeStream =>
      _streams[_active?.server] ??
      (_streams.isEmpty ? null : _streams.values.first);

  /// True when the playing server offers subtitles for this episode.
  bool get hasSubtitles => pickSubtitle(
          _streams[_active?.server]?.subtitles ?? const <Subtitle>[]) !=
      null;

  /// Quality labels offered by the active server for this episode, best first.
  List<String> get availableQualities {
    final s = _activeStream;
    final labels = <String>[];
    for (final q in s?.qualities ?? const <VideoQuality>[]) {
      if (q.url.isNotEmpty && !labels.contains(q.label)) labels.add(q.label);
    }
    return labels;
  }

  /// Resolve + initialize (no-op if already loading/ready).
  Future<void> load() async {
    if (_disposed) return;
    if (_status == EpisodeStatus.loading ||
        _status == EpisodeStatus.ready ||
        _status == EpisodeStatus.locked) {
      return;
    }
    await _open(at: _startAt, quality: _quality);
  }

  /// Retry after an error: forget failures and cached stream info.
  Future<void> retry() async {
    if (_disposed || isLocked) return;
    _startAt = _lastPosition;
    _failedUrls.clear();
    _streams.clear();
    _status = EpisodeStatus.idle;
    await load();
  }

  void play() {
    _wantPlay = true;
    final v = _video;
    if (isReady && v != null) v.play();
    _notify();
  }

  void pause() {
    _wantPlay = false;
    _video?.pause();
    _notify();
  }

  Future<void> seekTo(Duration to) async {
    final v = _video;
    if (!isReady || v == null) {
      _startAt = to;
      return;
    }
    await v.seekTo(to);
  }

  void setSpeed(double speed) {
    _speed = speed;
    final v = _video;
    if (isReady && v != null) v.setPlaybackSpeed(speed);
  }

  /// Switch quality keeping position and play state. The current stream keeps
  /// playing until the new one is ready; if the new one fails it stays.
  Future<void> switchQuality(String label) async {
    if (_disposed) return;
    _quality = label;
    if (!isReady) {
      if (_status == EpisodeStatus.error) await retry();
      return;
    }
    if (label == _active?.label) return;
    _switching = true;
    _notify();
    await _open(at: position, quality: label, keepCurrent: true);
    if (_disposed) return;
    _switching = false;
    _notify();
  }

  // ---------------------------------------------------------------------------

  bool _stale(int gen) => _disposed || gen != _gen;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  List<String> _servers() {
    try {
      final list = Catalog.instance.servers(detail);
      if (list.isNotEmpty) return list;
    } catch (e) {
      debugPrint('[player] servers() failed: $e');
    }
    return const [''];
  }

  Stream<_Source> _sources(String quality) async* {
    final seen = <String>{};
    for (final server in _servers()) {
      var s = _streams[server];
      if (s == null) {
        try {
          s = await Catalog.instance
              .episode(detail, ep, server: server)
              .timeout(_resolveTimeout);
          _streams[server] = s;
        } on EpisodeLockedException catch (e) {
          debugPrint('[player] ep$ep locked on $server: $e');
          _lockedHit = true;
          return; // known-unavailable: don't try other servers
        } catch (e) {
          debugPrint('[player] resolve ep$ep $server failed: $e');
          continue;
        }
      }
      final picked = pickQuality(s.qualities, quality);
      var playLabel = 'Auto';
      var playHls = s.isHls;
      for (final q in s.qualities) {
        if (q.url == s.playUrl) {
          playLabel = q.label;
          playHls = q.isHls;
        }
      }
      final h = s.headers;
      final candidates = <_Source>[
        if (picked != null)
          _Source(picked.url, picked.label, server,
              isHls: picked.isHls, headers: h),
        _Source(s.playUrl, playLabel, server, isHls: playHls, headers: h),
        _Source(s.proxyUrl, playLabel, server, isHls: s.isHls, headers: h),
        for (final q in s.qualities)
          _Source(q.url, q.label, server, isHls: q.isHls, headers: h),
      ];
      for (final c in candidates) {
        if (c.url.isNotEmpty && seen.add(c.url)) yield c;
      }
    }
  }

  Future<void> _open({
    required Duration at,
    required String quality,
    bool keepCurrent = false,
  }) async {
    final gen = ++_gen;
    _lockedHit = false;
    if (!keepCurrent) {
      _status = EpisodeStatus.loading;
      _error = null;
      _notify();
    }
    Object? lastError;
    await for (final src in _sources(quality)) {
      if (_stale(gen)) return;
      if (_failedUrls.contains(src.url)) continue;
      if (keepCurrent && src.url == _active?.url) continue;

      final Uri uri;
      try {
        uri = Uri.parse(src.url);
      } catch (_) {
        _failedUrls.add(src.url);
        continue;
      }
      final c = VideoPlayerController.networkUrl(
        uri,
        // Proxy URLs often have no telling extension, so HLS must be hinted.
        // Progressive MP4: no hint, ExoPlayer sniffs the container.
        formatHint: src.isHls ? VideoFormat.hls : null,
        httpHeaders: src.headers,
      );
      try {
        await c.initialize().timeout(_initTimeout);
        // For quality switches, catch up with where the old stream is now.
        final seekTo = keepCurrent && _video != null ? position : at;
        if (seekTo > Duration.zero) await c.seekTo(seekTo);
        if (_speed != 1.0) await c.setPlaybackSpeed(_speed);
      } catch (e) {
        debugPrint('[player] ep$ep ${src.server} ${src.label} failed: $e');
        lastError = e;
        _failedUrls.add(src.url);
        unawaited(c.dispose());
        continue;
      }
      if (_stale(gen)) {
        unawaited(c.dispose());
        return;
      }
      _attach(c, src);
      return;
    }
    if (_stale(gen)) return;
    if (keepCurrent && _video != null) return; // keep what's playing
    if (_lockedHit) {
      _status = EpisodeStatus.locked;
      _error = lockedMessage;
      _notify();
      onLocked?.call();
      return;
    }
    _status = EpisodeStatus.error;
    _error = lastError == null
        ? "Couldn't resolve this episode"
        : "Couldn't play this episode";
    _notify();
  }

  void _attach(VideoPlayerController c, _Source src) {
    final old = _video;
    old?.removeListener(_onVideo);
    _video = c;
    _active = src;
    _status = EpisodeStatus.ready;
    _error = null;
    _completedFired = false;
    _lastPosition = c.value.position;
    c.addListener(_onVideo);
    if (_wantPlay) c.play();
    _notify();
    if (old != null) {
      old.pause();
      _disposeAfterFrame(old);
    }
    _attachCaptions(c, src);
  }

  /// Loads the active server's subtitle (English preferred) into [c] once it
  /// arrives. Failures only cost the captions, never playback.
  Future<void> _attachCaptions(VideoPlayerController c, _Source src) async {
    final sub = pickSubtitle(
        _streams[src.server]?.subtitles ?? const <Subtitle>[]);
    if (sub == null) return;
    final file = await _captions.putIfAbsent(
        sub.url, () => _loadCaptions(sub.url, src.headers));
    if (file == null || _disposed || !identical(_video, c)) return;
    try {
      await c.setClosedCaptionFile(Future.value(file));
    } catch (e) {
      debugPrint('[player] captions attach failed: $e');
    }
  }

  static Future<ClosedCaptionFile?> _loadCaptions(
      String url, Map<String, String> headers) async {
    try {
      final res = await http
          .get(Uri.parse(url), headers: headers)
          .timeout(_subtitleTimeout);
      if (res.statusCode != 200) {
        debugPrint('[player] subtitles HTTP ${res.statusCode}');
        return null;
      }
      var raw = utf8.decode(res.bodyBytes, allowMalformed: true);
      // Some providers (wetv) wrap the VTT in an HLS subtitle playlist:
      // fetch its segments and join them.
      if (raw.trimLeft().startsWith('#EXTM3U')) {
        final base = Uri.parse(url);
        final parts = <String>[];
        for (final line in const LineSplitter().convert(raw)) {
          final l = line.trim();
          if (l.isEmpty || l.startsWith('#')) continue;
          final seg = await http
              .get(base.resolve(l), headers: headers)
              .timeout(_subtitleTimeout);
          if (seg.statusCode != 200) continue;
          var body = utf8.decode(seg.bodyBytes, allowMalformed: true);
          if (parts.isNotEmpty) {
            body = body.replaceFirst(RegExp(r'^﻿?WEBVTT[^\n]*\n'), '');
          }
          parts.add(body);
        }
        raw = parts.join('\n');
      }
      final file = WebVTTCaptionFile(cleanVtt(raw));
      return file.captions.isEmpty ? null : file;
    } catch (e) {
      debugPrint('[player] subtitles failed: $e');
      return null;
    }
  }

  /// Let the widget tree rebuild onto the new controller before disposing.
  void _disposeAfterFrame(VideoPlayerController c) {
    WidgetsBinding.instance.addPostFrameCallback((_) => c.dispose());
    WidgetsBinding.instance.scheduleFrame();
  }

  void _onVideo() {
    final v = _video;
    if (v == null || _disposed) return;
    final value = v.value;
    if (value.hasError) {
      if (!_recovering) _recover();
      return;
    }
    if (value.isInitialized) _lastPosition = value.position;

    if (value.isCompleted && !_completedFired) {
      _completedFired = true;
      onCompleted?.call();
    } else if (!value.isCompleted) {
      _completedFired = false;
    }

    if (value.isPlaying != _lastPlaying ||
        value.isBuffering != _lastBuffering ||
        value.isCompleted != _lastCompleted) {
      _lastPlaying = value.isPlaying;
      _lastBuffering = value.isBuffering;
      _lastCompleted = value.isCompleted;
      _notify();
    }
  }

  /// A stream that was playing errored: move to the next source at the same
  /// position.
  Future<void> _recover() async {
    final old = _video;
    if (old == null) return;
    _recovering = true;
    debugPrint('[player] ep$ep playback error: ${old.value.errorDescription}');
    if (_active != null) _failedUrls.add(_active!.url);
    old.removeListener(_onVideo);
    _video = null;
    _active = null;
    _disposeAfterFrame(old);
    await _open(at: _lastPosition, quality: _quality);
    _recovering = false;
  }

  @override
  void dispose() {
    _disposed = true;
    _gen++;
    final v = _video;
    _video = null;
    if (v != null) {
      v.removeListener(_onVideo);
      v.dispose();
    }
    super.dispose();
  }
}
