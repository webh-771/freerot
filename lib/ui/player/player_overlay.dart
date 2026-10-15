// OWNER: player agent.
//
// Thin controls drawn over the current page: back + title + "EP n / N",
// center play/pause, slim seek bar with times, and a small right-side rail
// (episodes, quality, speed, CC when the stream has subtitles), plus the
// caption layer drawn under the controls. Transparent areas never absorb taps, so the
// page's tap/drag gestures still reach the PageView.
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'episode_player.dart';
import 'sheets.dart';

String formatDuration(Duration d) {
  final s = d.inSeconds.clamp(0, 1 << 31);
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = (s % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$sec' : '$m:$sec';
}

class PlayerOverlay extends StatelessWidget {
  final EpisodeController? controller;
  final bool visible;
  final String title;
  final int ep;
  final int total;
  final double speed;
  final VoidCallback onBack;
  final VoidCallback onTogglePlay;
  final VoidCallback onEpisodes;
  final VoidCallback onQuality;
  final VoidCallback onSpeed;

  /// Captions currently shown (CC button state).
  final bool captionsOn;
  final VoidCallback onCaptions;

  /// Any interaction with the controls (keeps them from auto-hiding).
  final VoidCallback onInteraction;

  const PlayerOverlay({
    super.key,
    required this.controller,
    required this.visible,
    required this.title,
    required this.ep,
    required this.total,
    required this.speed,
    required this.onBack,
    required this.onTogglePlay,
    required this.onEpisodes,
    required this.onQuality,
    required this.onSpeed,
    required this.captionsOn,
    required this.onCaptions,
    required this.onInteraction,
  });

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Always-on hairline progress while controls are hidden.
        if (c != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: visible ? 0 : 1,
                duration: const Duration(milliseconds: 200),
                child: _HairlineProgress(controller: c),
              ),
            ),
          ),
        // Paused indicator stays visible even with controls hidden.
        if (c != null)
          Center(
            child: ListenableBuilder(
              listenable: c,
              builder: (context, _) {
                final ready = c.isReady && !c.isSwitching;
                final playing = c.isPlaying || c.wantsPlay;
                final buffering = c.video?.value.isBuffering ?? false;
                final show =
                    ready && !buffering && (visible || !playing);
                return IgnorePointer(
                  ignoring: !show,
                  child: AnimatedOpacity(
                    opacity: show ? 1 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: _RoundButton(
                      size: 60,
                      icon: playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      iconSize: 34,
                      onTap: onTogglePlay,
                    ),
                  ),
                );
              },
            ),
          ),
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !visible,
            child: AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: _controls(context, c),
            ),
          ),
        ),
      ],
    );
  }

  Widget _controls(BuildContext context, EpisodeController? c) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Scrims (non-interactive) for legibility.
        const Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 120,
          child: IgnorePointer(child: _Scrim(top: true)),
        ),
        const Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          height: 150,
          child: IgnorePointer(child: _Scrim(top: false)),
        ),
        SafeArea(
          child: Stack(
            children: [
              Positioned(
                top: 4,
                left: 4,
                right: 16,
                child: Row(
                  children: [
                    IconButton(
                      onPressed: onBack,
                      icon: const Icon(Icons.arrow_back_ios_new_rounded,
                          size: 20),
                      color: Colors.white,
                      tooltip: 'Back',
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'EP $ep / $total',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                right: 8,
                bottom: 72,
                child: _SideRail(
                  controller: c,
                  speed: speed,
                  onEpisodes: onEpisodes,
                  onQuality: onQuality,
                  onSpeed: onSpeed,
                  captionsOn: captionsOn,
                  onCaptions: onCaptions,
                ),
              ),
              if (c != null)
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 8,
                  child: ListenableBuilder(
                    listenable: c,
                    builder: (context, _) {
                      final v = c.video;
                      if (!c.isReady || v == null) {
                        return const SizedBox(height: 44);
                      }
                      return _SeekBar(
                        key: ValueKey(v),
                        controller: c,
                        video: v,
                        onInteraction: onInteraction,
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Scrim extends StatelessWidget {
  final bool top;
  const _Scrim({required this.top});

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: top ? Alignment.topCenter : Alignment.bottomCenter,
            end: top ? Alignment.bottomCenter : Alignment.topCenter,
            colors: const [Color(0x99000000), Color(0x00000000)],
          ),
        ),
      );
}

class _SideRail extends StatelessWidget {
  final EpisodeController? controller;
  final double speed;
  final VoidCallback onEpisodes;
  final VoidCallback onQuality;
  final VoidCallback onSpeed;
  final bool captionsOn;
  final VoidCallback onCaptions;

  const _SideRail({
    required this.controller,
    required this.speed,
    required this.onEpisodes,
    required this.onQuality,
    required this.onSpeed,
    required this.captionsOn,
    required this.onCaptions,
  });

  @override
  Widget build(BuildContext context) {
    final c = controller;
    Widget quality(String? label) => _RailButton(
          label: 'Quality',
          onTap: onQuality,
          child: Text(
            (label == null || label == 'Auto') ? 'HD' : label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _RailButton(
          label: 'Episodes',
          onTap: onEpisodes,
          child: const Icon(Icons.video_library_outlined,
              color: Colors.white, size: 20),
        ),
        const SizedBox(height: 14),
        c == null
            ? quality(null)
            : ListenableBuilder(
                listenable: c,
                builder: (context, _) => quality(c.activeQuality),
              ),
        const SizedBox(height: 14),
        _RailButton(
          label: 'Speed',
          onTap: onSpeed,
          child: Text(
            formatSpeed(speed),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (c != null)
          ListenableBuilder(
            listenable: c,
            builder: (context, _) {
              if (!c.hasSubtitles) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 14),
                child: _RailButton(
                  label: 'Captions',
                  onTap: onCaptions,
                  child: Icon(
                    captionsOn
                        ? Icons.closed_caption_rounded
                        : Icons.closed_caption_disabled_outlined,
                    color: captionsOn ? Colors.white : Colors.white54,
                    size: 20,
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

class _RailButton extends StatelessWidget {
  final String label;
  final Widget child;
  final VoidCallback onTap;
  const _RailButton({
    required this.label,
    required this.child,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 52,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                color: Color(0x33000000),
                shape: BoxShape.circle,
              ),
              child: child,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 10,
                shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  final double size;
  final IconData icon;
  final double iconSize;
  final VoidCallback onTap;
  const _RoundButton({
    required this.size,
    required this.icon,
    required this.iconSize,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          color: Color(0x40000000),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: iconSize),
      ),
    );
  }
}

class _HairlineProgress extends StatelessWidget {
  final EpisodeController controller;
  const _HairlineProgress({required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final v = controller.video;
        if (!controller.isReady || v == null) return const SizedBox(height: 2);
        return ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: v,
          builder: (context, value, _) {
            final d = value.duration.inMilliseconds;
            final f = d <= 0 ? 0.0 : value.position.inMilliseconds / d;
            return Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: f.clamp(0.0, 1.0),
                child: Container(height: 2, color: Colors.white70),
              ),
            );
          },
        );
      },
    );
  }
}

class _SeekBar extends StatefulWidget {
  final EpisodeController controller;
  final VideoPlayerController video;
  final VoidCallback onInteraction;
  const _SeekBar({
    super.key,
    required this.controller,
    required this.video,
    required this.onInteraction,
  });

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  double? _dragMs;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: widget.video,
      builder: (context, value, _) {
        final durMs = value.duration.inMilliseconds.toDouble();
        final max = durMs <= 0 ? 1.0 : durMs;
        final posMs =
            (_dragMs ?? value.position.inMilliseconds.toDouble()).clamp(0.0, max);
        var buffered = 0.0;
        for (final r in value.buffered) {
          final end = r.end.inMilliseconds.toDouble();
          if (end > buffered) buffered = end;
        }
        const timeStyle = TextStyle(
          color: Colors.white70,
          fontSize: 11,
          fontFeatures: [FontFeature.tabularFigures()],
        );
        return Row(
          children: [
            SizedBox(
              width: 40,
              child: Text(
                formatDuration(Duration(milliseconds: posMs.round())),
                style: timeStyle,
              ),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2,
                  activeTrackColor: Colors.white,
                  inactiveTrackColor: Colors.white24,
                  secondaryActiveTrackColor: Colors.white38,
                  thumbColor: Colors.white,
                  overlayColor: Colors.white12,
                  thumbShape: RoundSliderThumbShape(
                    enabledThumbRadius: _dragMs != null ? 7 : 5,
                  ),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 14),
                  trackShape: const RoundedRectSliderTrackShape(),
                ),
                child: Slider(
                  value: posMs,
                  max: max,
                  secondaryTrackValue: buffered.clamp(0.0, max),
                  onChangeStart: (v) {
                    widget.onInteraction();
                    setState(() => _dragMs = v);
                  },
                  onChanged: (v) {
                    widget.onInteraction();
                    setState(() => _dragMs = v);
                  },
                  onChangeEnd: (v) async {
                    widget.onInteraction();
                    await widget.controller
                        .seekTo(Duration(milliseconds: v.round()));
                    if (mounted) setState(() => _dragMs = null);
                  },
                ),
              ),
            ),
            SizedBox(
              width: 40,
              child: Text(
                formatDuration(value.duration),
                textAlign: TextAlign.right,
                style: timeStyle,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Current caption line, centered near the bottom: white text with a soft
/// dark shadow, no box. Sits above the seek bar while controls are shown.
class CaptionLayer extends StatelessWidget {
  final EpisodeController controller;

  /// Controls visible: lift the text above the seek bar and side rail.
  final bool raised;

  const CaptionLayer({super.key, required this.controller, required this.raised});

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: SafeArea(
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final v = controller.video;
              if (!controller.isReady || v == null) {
                return const SizedBox.shrink();
              }
              return ValueListenableBuilder<VideoPlayerValue>(
                valueListenable: v,
                builder: (context, value, _) {
                  final text = value.caption.text.trim();
                  return AnimatedPadding(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    padding: EdgeInsets.fromLTRB(
                      raised ? 64 : 24,
                      0,
                      raised ? 64 : 24,
                      raised ? 64 : 28,
                    ),
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: text.isEmpty
                          ? const SizedBox.shrink()
                          : Text(
                              text,
                              textAlign: TextAlign.center,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                height: 1.3,
                                fontWeight: FontWeight.w500,
                                shadows: [
                                  Shadow(
                                      color: Color(0xCC000000),
                                      blurRadius: 4,
                                      offset: Offset(0, 1)),
                                  Shadow(
                                      color: Color(0x80000000),
                                      blurRadius: 10),
                                ],
                              ),
                            ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}
