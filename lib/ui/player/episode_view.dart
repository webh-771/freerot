// OWNER: player agent.
//
// The video surface for one page: fitted video, cover placeholder while
// loading, thin buffering spinner and a compact error + Retry.
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'episode_player.dart';

class EpisodeVideo extends StatelessWidget {
  final EpisodeController? controller;
  final String cover;

  const EpisodeVideo({super.key, required this.controller, required this.cover});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (c == null) return _Placeholder(cover: cover, loading: true);
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final video = c.video;
        if (!c.isReady || video == null) {
          return _Placeholder(
            cover: cover,
            loading: c.status == EpisodeStatus.idle ||
                c.status == EpisodeStatus.loading,
          );
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            _FittedVideo(key: ValueKey(video), video: video),
            if (video.value.isBuffering || c.isSwitching)
              const Center(child: ThinSpinner()),
          ],
        );
      },
    );
  }
}

/// Error message with a Retry button (or a quiet "not available" note for a
/// locked episode — nothing to retry). Placed above the tap layer so the
/// button receives taps.
class EpisodeError extends StatelessWidget {
  final EpisodeController? controller;
  const EpisodeError({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (c == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        if (c.status == EpisodeStatus.locked) {
          return const IgnorePointer(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock_outline_rounded,
                      color: Colors.white54, size: 26),
                  SizedBox(height: 10),
                  Text(
                    EpisodeController.lockedMessage,
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
            ),
          );
        }
        if (c.status != EpisodeStatus.error) return const SizedBox.shrink();
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded,
                  color: Colors.white54, size: 28),
              const SizedBox(height: 10),
              Text(
                c.error ?? "Couldn't play this episode",
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: c.retry,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white38, width: 1),
                  shape: const StadiumBorder(),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 22, vertical: 8),
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('Retry', style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
        );
      },
    );
  }
}

class ThinSpinner extends StatelessWidget {
  final double size;
  const ThinSpinner({super.key, this.size = 28});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: const CircularProgressIndicator(
          strokeWidth: 1.5,
          color: Colors.white70,
        ),
      );
}

class _Placeholder extends StatelessWidget {
  final String cover;
  final bool loading;
  const _Placeholder({required this.cover, required this.loading});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),
        if (cover.isNotEmpty)
          Opacity(
            opacity: 0.25,
            child: Image.network(
              cover,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
        if (loading) const Center(child: ThinSpinner()),
      ],
    );
  }
}

/// Cover-fit when the video and screen are both portrait with similar aspect
/// (phones, 9:16 video) — slight crop, no bars. Contain otherwise (landscape,
/// tablets, or non-vertical video).
class _FittedVideo extends StatelessWidget {
  final VideoPlayerController video;
  const _FittedVideo({super.key, required this.video});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final size = video.value.size;
        final hasSize = size.width > 0 && size.height > 0;
        final vw = hasSize ? size.width : 9.0;
        final vh = hasSize ? size.height : 16.0;
        final videoAr = vw / vh;
        final screenAr = box.maxWidth / box.maxHeight;
        final cover = videoAr < 1 &&
            screenAr < 1 &&
            ((videoAr - screenAr).abs() / videoAr) < 0.3;
        return ClipRect(
          child: FittedBox(
            fit: cover ? BoxFit.cover : BoxFit.contain,
            child: SizedBox(width: vw, height: vh, child: VideoPlayer(video)),
          ),
        );
      },
    );
  }
}
