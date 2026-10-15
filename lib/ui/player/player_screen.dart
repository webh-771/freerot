// OWNER: player agent. Constructor is a contract used by UI screens.
//
// TikTok-style vertical pager, one page per episode. Orchestrates:
//  - at most 3 live EpisodeControllers (prev / current / next); the next one
//    is preloaded once the current one is actually playing,
//  - autoplay-next on completion, "Finished" at the last episode,
//  - locked episodes: detail.locked ones get no page at all (swipe, autoplay
//    and preload skip them; the episode sheet shows them greyed); ones the
//    catalog reports locked at play time show "not available" and are
//    skipped when we got there by autoplay,
//  - captions (CC toggle, remembered for the session) when a stream has
//    subtitles,
//  - progress saving (every 5s while playing, on pause, page change, app
//    background, dispose),
//  - wakelock, immersive system UI, free rotation (restored on exit).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../data/library.dart';
import '../../models.dart';
import 'episode_player.dart';
import 'episode_view.dart';
import 'player_overlay.dart';
import 'sheets.dart';

class PlayerScreen extends StatefulWidget {
  final DramaDetail detail;
  final int startEp;

  /// Resume offset for [startEp] (0 = from start).
  final int startPositionMs;

  const PlayerScreen({
    super.key,
    required this.detail,
    required this.startEp,
    this.startPositionMs = 0,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  static const _hideAfter = Duration(seconds: 3);
  static const _saveEvery = Duration(seconds: 5);

  /// Captions on/off, remembered across players for this app session.
  static bool _captionsOn = true;

  /// Every listed episode (for the episode sheet).
  late final List<int> _allEps;

  /// Playable episodes = one page each (detail.locked removed).
  late final List<int> _eps;

  /// Episodes the catalog reported locked while playing.
  final Set<int> _runtimeLocked = {};

  /// Page we moved to by autoplay; if it turns out locked we keep going.
  int? _autoTarget;

  late final Drama _drama;
  late final PageController _pages;
  late int _index;

  final Map<int, EpisodeController> _ctrls = {};
  String _quality = '720p';
  double _speed = 1.0;

  bool _controlsVisible = true;
  bool _finished = false;
  Timer? _hideTimer;
  Timer? _saveTimer;

  int get _total => widget.detail.totalEpisodes > 0
      ? widget.detail.totalEpisodes
      : _allEps.length;

  EpisodeController? get _current => _ctrls[_index];

  // ---------------------------------------------------------------- lifecycle

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final d = widget.detail;
    _allEps = d.episodes.isNotEmpty
        ? List<int>.of(d.episodes)
        : List<int>.generate(d.totalEpisodes, (i) => i + 1);
    _eps = _allEps.where((e) => !d.locked.contains(e)).toList();
    _drama = d.toDrama();
    final start = _eps.indexOf(widget.startEp);
    if (start >= 0) {
      _index = start;
    } else {
      // Start ep is locked / unknown: first playable one after it.
      final after = _eps.indexWhere((e) => e > widget.startEp);
      _index = after < 0 ? 0 : after;
    }
    _pages = PageController(initialPage: _index);

    _enterPlayerChrome();

    if (_eps.isNotEmpty) {
      _activate(
        _index,
        startAt: start < 0
            ? Duration.zero
            : Duration(milliseconds: widget.startPositionMs),
      );
    }
    _saveTimer = Timer.periodic(_saveEvery, (_) {
      if (_current?.isPlaying ?? false) _saveProgress(_index);
    });
    _scheduleHide();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _saveProgress(_index);
      case AppLifecycleState.resumed:
        _enterPlayerChrome();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _saveTimer?.cancel();
    _saveProgress(_index);
    for (final c in _ctrls.values) {
      c.dispose();
    }
    _ctrls.clear();
    _pages.dispose();
    _exitPlayerChrome();
    super.dispose();
  }

  void _enterPlayerChrome() {
    _safe(() => WakelockPlus.enable());
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  }

  void _exitPlayerChrome() {
    _safe(() => WakelockPlus.disable());
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
  }

  // ------------------------------------------------------------- controllers

  EpisodeController _ensure(int i, {Duration startAt = Duration.zero}) {
    return _ctrls.putIfAbsent(i, () {
      final c = EpisodeController(
        detail: widget.detail,
        ep: _eps[i],
        quality: _quality,
        startAt: startAt,
        speed: _speed,
      );
      c.onCompleted = () => _onCompleted(i);
      c.onLocked = () => _onLocked(i);
      c.addListener(() => _onControllerChanged(i));
      c.load();
      return c;
    });
  }

  void _activate(int i, {Duration startAt = Duration.zero}) {
    final c = _ensure(i, startAt: startAt);
    for (final e in _ctrls.entries) {
      if (e.key != i) e.value.pause();
    }
    c.play();
    _trim(i);
    _maybePreload(i);
  }

  /// Keep only prev / current / next alive.
  void _trim(int i) {
    final far = _ctrls.keys.where((k) => (k - i).abs() > 1).toList();
    for (final k in far) {
      final c = _ctrls.remove(k)!;
      c.pause();
      // Let the page that may still show it rebuild first.
      WidgetsBinding.instance.addPostFrameCallback((_) => c.dispose());
    }
  }

  void _maybePreload(int i) {
    final next = i + 1;
    if (next >= _eps.length || _ctrls.containsKey(next)) return;
    if (_runtimeLocked.contains(_eps[next])) return;
    final c = _ctrls[i];
    if (c == null || !c.isReady || !c.isPlaying) return;
    if (c.video?.value.isBuffering ?? false) return;
    _ensure(next); // loads paused; ExoPlayer buffers the first segments
  }

  void _onControllerChanged(int i) {
    if (!mounted || i != _index) return;
    _maybePreload(i);
    final c = _ctrls[i];
    if (c == null) return;
    if (c.isPlaying) {
      if (_controlsVisible && _hideTimer == null) _scheduleHide();
    } else {
      _hideTimer?.cancel();
      _hideTimer = null;
    }
  }

  /// Next page after [i] not known to be locked, or -1.
  int _nextPlayable(int i) {
    for (var j = i + 1; j < _eps.length; j++) {
      if (!_runtimeLocked.contains(_eps[j])) return j;
    }
    return -1;
  }

  /// Autoplay: move on to the next playable episode, or show "Finished".
  void _advanceFrom(int i) {
    final next = _nextPlayable(i);
    if (next >= 0) {
      _autoTarget = next;
      if (next == i + 1) {
        _pages.animateToPage(
          next,
          duration: const Duration(milliseconds: 380),
          curve: Curves.easeOutCubic,
        );
      } else {
        _pages.jumpToPage(next);
      }
    } else {
      _hideTimer?.cancel();
      setState(() {
        _finished = true;
        _controlsVisible = true;
      });
    }
  }

  void _onCompleted(int i) {
    if (!mounted || i != _index) return;
    _saveProgress(i);
    _advanceFrom(i);
  }

  void _onLocked(int i) {
    if (!mounted || i >= _eps.length) return;
    setState(() => _runtimeLocked.add(_eps[i]));
    // Reached by autoplay: don't stall on it, keep going.
    if (i == _index && _autoTarget == i) _advanceFrom(i);
  }

  void _onPageChanged(int i) {
    if (i != _autoTarget) _autoTarget = null;
    if (i == _index) return;
    _saveProgress(_index);
    setState(() {
      _index = i;
      _finished = false;
    });
    _activate(i);
    _scheduleHide();
  }

  // ---------------------------------------------------------------- progress

  void _saveProgress(int i) {
    if (i < 0 || i >= _eps.length) return;
    final c = _ctrls[i];
    if (c == null || !c.isReady) return;
    final dur = c.duration.inMilliseconds;
    if (dur <= 0) return;
    final pos = c.position.inMilliseconds.clamp(0, dur);
    final ep = _eps[i];
    // Library is another agent's code; never let it break playback.
    _safe(() => Library.instance.saveProgress(_drama, ep, pos, dur));
  }

  static void _safe(FutureOr<void> Function() f) {
    try {
      final r = f();
      if (r is Future<void>) {
        r.catchError((Object e) => debugPrint('[player] $e'));
      }
    } catch (e) {
      debugPrint('[player] $e');
    }
  }

  // ---------------------------------------------------------------- controls

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = null;
    if (!(_current?.wantsPlay ?? false) || _finished) return;
    _hideTimer = Timer(_hideAfter, () {
      _hideTimer = null;
      if (mounted && (_current?.isPlaying ?? false)) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
  }

  void _poke() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  void _togglePlay() {
    final c = _current;
    if (c == null) return;
    if (c.isPlaying || c.wantsPlay) {
      c.pause();
      _saveProgress(_index);
      _hideTimer?.cancel();
      _hideTimer = null;
      if (!_controlsVisible) setState(() => _controlsVisible = true);
    } else {
      if (_finished) setState(() => _finished = false);
      c.play();
      _scheduleHide();
    }
  }

  void _replay() {
    final c = _current;
    if (c == null) return;
    setState(() => _finished = false);
    c.seekTo(Duration.zero).then((_) {
      if (mounted) c.play();
    });
    _scheduleHide();
  }

  Future<void> _openSheet(Future<void> Function() body) async {
    _hideTimer?.cancel();
    _hideTimer = null;
    await body();
    if (mounted) _poke();
  }

  void _showEpisodes() => _openSheet(() async {
        final ep = await showEpisodeSheet(
          context,
          episodes: _allEps,
          locked: {...widget.detail.locked, ..._runtimeLocked},
          current: _eps[_index],
        );
        if (!mounted || ep == null) return;
        final i = _eps.indexOf(ep);
        if (i < 0 || i == _index) return;
        if ((i - _index).abs() == 1) {
          _pages.animateToPage(i,
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic);
        } else {
          _pages.jumpToPage(i);
        }
      });

  void _showQuality() => _openSheet(() async {
        final c = _current;
        final offered = c?.availableQualities ?? const <String>[];
        final active = c?.activeQuality;
        final picked = await showQualitySheet(
          context,
          // Nothing to choose when the server offers a single stream.
          options: offered.isNotEmpty ? offered : [active ?? 'Auto'],
          current: active ?? _quality,
        );
        if (!mounted || picked == null) return;
        if (offered.isEmpty) return;
        _quality = picked;
        // Neighbours were loaded at the old quality; drop them so they reload.
        for (final k in _ctrls.keys.where((k) => k != _index).toList()) {
          final old = _ctrls.remove(k)!;
          WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
        }
        setState(() {});
        await _current?.switchQuality(picked);
      });

  void _showSpeed() => _openSheet(() async {
        final s = await showSpeedSheet(context, current: _speed);
        if (!mounted || s == null) return;
        setState(() => _speed = s);
        for (final c in _ctrls.values) {
          c.setSpeed(s);
        }
      });

  void _toggleCaptions() {
    setState(() => _captionsOn = !_captionsOn);
    _poke();
  }

  // ------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final d = widget.detail;
    return Scaffold(
      backgroundColor: Colors.black,
      body: _eps.isEmpty
          ? _empty(context)
          : PageView.builder(
              controller: _pages,
              scrollDirection: Axis.vertical,
              itemCount: _eps.length,
              onPageChanged: _onPageChanged,
              itemBuilder: (context, i) {
                final c = _ctrls[i];
                final isCurrent = i == _index;
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: isCurrent ? _toggleControls : null,
                      child: EpisodeVideo(controller: c, cover: d.cover),
                    ),
                    EpisodeError(controller: c),
                    if (isCurrent && _captionsOn && c != null)
                      CaptionLayer(controller: c, raised: _controlsVisible),
                    if (isCurrent)
                      PlayerOverlay(
                        controller: c,
                        visible: _controlsVisible,
                        title: d.title,
                        ep: _eps[i],
                        total: _total,
                        speed: _speed,
                        onBack: () => Navigator.of(context).maybePop(),
                        onTogglePlay: _togglePlay,
                        onEpisodes: _showEpisodes,
                        onQuality: _showQuality,
                        onSpeed: _showSpeed,
                        captionsOn: _captionsOn,
                        onCaptions: _toggleCaptions,
                        onInteraction: _poke,
                      ),
                    if (isCurrent && _finished)
                      _FinishedBadge(onReplay: _replay),
                  ],
                );
              },
            ),
    );
  }

  Widget _empty(BuildContext context) => SafeArea(
        child: Stack(
          children: [
            IconButton(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
              color: Colors.white,
            ),
            const Center(
              child: Text('No episodes available',
                  style: TextStyle(color: Colors.white54, fontSize: 13)),
            ),
          ],
        ),
      );
}

class _FinishedBadge extends StatelessWidget {
  final VoidCallback onReplay;
  const _FinishedBadge({required this.onReplay});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: const Alignment(0, 0.35),
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 10, 8, 10),
        decoration: BoxDecoration(
          color: const Color(0xB3000000),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Finished',
              style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
              ),
            ),
            const SizedBox(width: 6),
            TextButton.icon(
              onPressed: onReplay,
              style: TextButton.styleFrom(
                foregroundColor: Colors.white70,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              icon: const Icon(Icons.replay_rounded, size: 16),
              label: const Text('Replay', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }
}
