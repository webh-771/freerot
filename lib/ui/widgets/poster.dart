import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../data/catalog.dart';
import '../../models.dart';
import '../theme.dart';

/// Human label for a drama's source ("NetShort", "ShortMax"...), or '' if the
/// catalog can't name it. Never throws — a label is decoration only.
String sourceName(String dramaSource) {
  try {
    return Catalog.instance.sourceLabel(dramaSource);
  } catch (_) {
    return '';
  }
}

/// Compact count: 999, 1.2K, 12.3K, 123K, 3.4M, 2B. Truncates (never rounds
/// up), so 999,999 is "999K" rather than "1000K".
String formatCompact(int n) {
  if (n < 1000) return n < 0 ? '0' : '$n';
  const units = ['K', 'M', 'B', 'T'];
  var v = n / 1000;
  var u = 0;
  while (v >= 1000 && u < units.length - 1) {
    v /= 1000;
    u++;
  }
  final String s;
  if (v >= 100) {
    s = v.floor().toString();
  } else {
    final t = (v * 10).floor() / 10;
    s = t == t.truncateToDouble() ? t.toInt().toString() : t.toStringAsFixed(1);
  }
  return '$s${units[u]}';
}

/// "1.2M views" / "1 view".
String formatViews(int n) => n == 1 ? '1 view' : '${formatCompact(n)} views';

/// Poster aspect ratio (width / height).
const double kPosterAspect = 3 / 4;

/// Bare 3:4 rounded cover image with a flat placeholder + error fallback.
class PosterImage extends StatelessWidget {
  final String url;
  final BorderRadius? borderRadius;
  final double? aspectRatio;

  const PosterImage({
    super.key,
    required this.url,
    this.borderRadius,
    this.aspectRatio = kPosterAspect,
  });

  @override
  Widget build(BuildContext context) {
    final radius = borderRadius ?? AppRadius.posterBorder;
    Widget img = url.isEmpty
        ? const _PosterFallback()
        : CachedNetworkImage(
            imageUrl: url,
            fit: BoxFit.cover,
            fadeInDuration: const Duration(milliseconds: 180),
            fadeOutDuration: Duration.zero,
            placeholder: (_, _) => const ColoredBox(color: AppColors.placeholder),
            errorWidget: (_, _, _) => const _PosterFallback(),
          );
    img = ClipRRect(
      borderRadius: radius,
      child: ColoredBox(color: AppColors.placeholder, child: img),
    );
    final ar = aspectRatio;
    return ar == null ? img : AspectRatio(aspectRatio: ar, child: img);
  }
}

class _PosterFallback extends StatelessWidget {
  const _PosterFallback();

  @override
  Widget build(BuildContext context) => const ColoredBox(
        color: AppColors.placeholder,
        child: Center(
          child: Icon(Icons.movie_outlined, color: AppColors.textFaint, size: 28),
        ),
      );
}

/// Reusable drama card: cover, optional progress bar/label, title below.
class Poster extends StatelessWidget {
  final Drama drama;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Show the title under the cover.
  final bool showTitle;

  /// 0..1; draws a thin bar along the bottom of the cover when non-null.
  final double? progress;

  /// Small label in the bottom-left of the cover (e.g. "EP 3").
  final String? badge;

  /// Optional line under the title (e.g. "42 episodes").
  final String? subtitle;

  const Poster({
    super.key,
    required this.drama,
    this.onTap,
    this.onLongPress,
    this.showTitle = true,
    this.progress,
    this.badge,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cover = Stack(
      fit: StackFit.passthrough,
      children: [
        PosterImage(url: drama.cover),
        if (badge != null)
          Positioned(
            left: 8,
            bottom: progress != null ? 10 : 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xB30B0B0C),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                badge!,
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                  color: AppColors.text,
                ),
              ),
            ),
          ),
        if (progress != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(AppRadius.poster)),
              child: LinearProgressIndicator(
                value: progress!.clamp(0.0, 1.0),
                minHeight: 3,
              ),
            ),
          ),
      ],
    );

    return Semantics(
      button: onTap != null,
      label: drama.title,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            cover,
            if (showTitle) ...[
              const SizedBox(height: 8),
              Text(
                drama.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.text,
                  fontWeight: FontWeight.w500,
                  height: 1.3,
                ),
              ),
            ],
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: AppColors.textFaint, fontSize: 11),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Flat grey block matching a [Poster] (cover + two title lines).
class PosterPlaceholder extends StatelessWidget {
  final bool showTitle;
  const PosterPlaceholder({super.key, this.showTitle = true});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        AspectRatio(
          aspectRatio: kPosterAspect,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.placeholder,
              borderRadius: AppRadius.posterBorder,
            ),
          ),
        ),
        if (showTitle) ...[
          const SizedBox(height: 10),
          const _Bar(widthFactor: 0.85),
          const SizedBox(height: 6),
          const _Bar(widthFactor: 0.5),
        ],
      ],
    );
  }
}

class _Bar extends StatelessWidget {
  final double widthFactor;
  const _Bar({required this.widthFactor});

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
        widthFactor: widthFactor,
        alignment: Alignment.centerLeft,
        child: Container(
          height: 9,
          decoration: BoxDecoration(
            color: AppColors.placeholder,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
      );
}
