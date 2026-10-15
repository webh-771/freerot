import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../data/catalog.dart';
import '../../data/library.dart';
import '../../models.dart';
import '../nav.dart';
import '../theme.dart';
import '../widgets/poster.dart';
import '../widgets/states.dart';

/// Drama page: cover, title, synopsis, play/continue, My List, episodes.
class DetailScreen extends StatefulWidget {
  /// What we already know from the card (shown instantly while loading).
  final Drama drama;

  const DetailScreen({super.key, required this.drama});

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  late Future<DramaDetail> _future;

  @override
  void initState() {
    super.initState();
    _future = Catalog.instance.detail(widget.drama);
  }

  void _retry() => setState(() {
        _future = Catalog.instance.detail(widget.drama);
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder<DramaDetail>(
        future: _future,
        builder: (context, snap) {
          final detail = snap.data;
          final drama = detail?.toDrama() ?? widget.drama;
          return CustomScrollView(
            slivers: [
              _CoverHeader(
                  cover: drama.cover.isNotEmpty ? drama.cover : widget.drama.cover),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                sliver: SliverToBoxAdapter(
                  child: _Info(
                    drama: drama,
                    detail: detail,
                    loading: snap.connectionState != ConnectionState.done,
                  ),
                ),
              ),
              if (snap.hasError)
                SliverToBoxAdapter(
                  child: ErrorView(error: snap.error, onRetry: _retry),
                )
              else if (detail == null)
                const SliverToBoxAdapter(child: _BodyPlaceholder())
              else
                _EpisodeGrid(detail: detail),
              SliverToBoxAdapter(
                child: SizedBox(
                    height: 32 + MediaQuery.paddingOf(context).bottom),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _CoverHeader extends StatelessWidget {
  final String cover;
  const _CoverHeader({required this.cover});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final height = math.min(size.height * 0.56, size.width * 4 / 3);
    return SliverAppBar(
      expandedHeight: height,
      pinned: true,
      stretch: true,
      backgroundColor: AppColors.background,
      leading: const _CircleBack(),
      flexibleSpace: FlexibleSpaceBar(
        stretchModes: const [StretchMode.zoomBackground],
        background: Stack(
          fit: StackFit.expand,
          children: [
            if (cover.isNotEmpty)
              CachedNetworkImage(
                imageUrl: cover,
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
                fadeInDuration: const Duration(milliseconds: 200),
                placeholder: (_, _) =>
                    const ColoredBox(color: AppColors.placeholder),
                errorWidget: (_, _, _) =>
                    const ColoredBox(color: AppColors.placeholder),
              )
            else
              const ColoredBox(color: AppColors.placeholder),
            // Single soft fade so the cover melts into the page.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0.55, 1.0],
                  colors: [Color(0x000B0B0C), AppColors.background],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CircleBack extends StatelessWidget {
  const _CircleBack();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Material(
        color: const Color(0x800B0B0C),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => Navigator.of(context).maybePop(),
          child: const Icon(Icons.arrow_back_rounded,
              color: AppColors.text, size: 22),
        ),
      ),
    );
  }
}

class _Info extends StatelessWidget {
  final Drama drama;
  final DramaDetail? detail;
  final bool loading;

  const _Info({required this.drama, required this.detail, required this.loading});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final eps = detail?.totalEpisodes ?? drama.episodes;
    final synopsis = (detail?.synopsis ?? drama.synopsis ?? '').trim();

    return ListenableBuilder(
      listenable: Library.instance,
      builder: (context, _) {
        final lib = Library.instance;
        final progress = lib.progressFor(drama.key);
        final saved = lib.inMyList(drama.key);
        final d = detail;
        final source = sourceName(drama.source);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(drama.title, style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              [
                if (eps != null && eps > 0) '$eps episodes',
                if (source.isNotEmpty) source,
                if (progress != null) 'Watching EP ${progress.ep}',
              ].join('  ·  '),
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: AppColors.textMuted),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: d == null
                        ? null
                        : () {
                            if (progress != null) {
                              openPlayer(context, d, progress.ep,
                                  positionMs: resumePositionFor(progress));
                            } else {
                              openPlayer(context, d, _firstPlayable(d));
                            }
                          },
                    icon: const Icon(Icons.play_arrow_rounded, size: 24),
                    label: Text(progress != null
                        ? 'Continue EP ${progress.ep}'
                        : 'Play'),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: () => lib.toggleMyList(drama),
                  icon: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: Icon(
                      saved ? Icons.check_rounded : Icons.add_rounded,
                      key: ValueKey(saved),
                      size: 22,
                      color: saved ? AppColors.accent : AppColors.text,
                    ),
                  ),
                  label: const Text('My List'),
                ),
              ],
            ),
            if (synopsis.isNotEmpty) ...[
              const SizedBox(height: 20),
              _Synopsis(text: synopsis),
            ],
            const SizedBox(height: 28),
            if (!loading || d != null)
              Text('Episodes', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
          ],
        );
      },
    );
  }
}

class _Synopsis extends StatefulWidget {
  final String text;
  const _Synopsis({required this.text});

  @override
  State<_Synopsis> createState() => _SynopsisState();
}

class _SynopsisState extends State<_Synopsis> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context)
        .textTheme
        .bodyMedium
        ?.copyWith(color: AppColors.textMuted);
    return LayoutBuilder(builder: (context, constraints) {
      final painter = TextPainter(
        text: TextSpan(text: widget.text, style: style),
        maxLines: 3,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: constraints.maxWidth);
      final overflows = painter.didExceedMaxLines;
      painter.dispose();

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: overflows ? () => setState(() => _expanded = !_expanded) : null,
        child: AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.text,
                style: style,
                maxLines: _expanded ? null : 3,
                overflow:
                    _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
              ),
              if (overflows)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _expanded ? 'Less' : 'More',
                    style: const TextStyle(
                      color: AppColors.text,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    });
  }
}

class _EpisodeGrid extends StatelessWidget {
  final DramaDetail detail;
  const _EpisodeGrid({required this.detail});

  @override
  Widget build(BuildContext context) {
    final eps = detail.episodes.isNotEmpty
        ? detail.episodes
        : [for (var i = 1; i <= detail.totalEpisodes; i++) i];
    if (eps.isEmpty) {
      return const SliverToBoxAdapter(
        child: EmptyView(message: 'No episodes listed yet.'),
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      sliver: ListenableBuilder(
        listenable: Library.instance,
        builder: (context, _) {
          final progress = Library.instance.progressFor(detail.key);
          final current = progress?.ep;
          return SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 5,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, i) {
                final ep = eps[i];
                final isCurrent = ep == current;
                final watched = current != null && ep < current;
                if (detail.locked.contains(ep)) {
                  return _EpisodeTile(
                    ep: ep,
                    current: false,
                    watched: false,
                    locked: true,
                    onTap: () => _notAvailable(context),
                  );
                }
                return _EpisodeTile(
                  ep: ep,
                  current: isCurrent,
                  watched: watched,
                  onTap: () => openPlayer(
                    context,
                    detail,
                    ep,
                    positionMs: isCurrent ? resumePositionFor(progress!) : 0,
                  ),
                );
              },
              childCount: eps.length,
            ),
          );
        },
      ),
    );
  }
}

void _notAvailable(BuildContext context) {
  final m = ScaffoldMessenger.of(context);
  m.hideCurrentSnackBar();
  m.showSnackBar(const SnackBar(
    content: Text('Not available'),
    duration: Duration(milliseconds: 1400),
  ));
}

/// First episode that isn't locked (falls back to the first listed).
int _firstPlayable(DramaDetail d) {
  final eps = d.episodes.isNotEmpty
      ? d.episodes
      : [for (var i = 1; i <= d.totalEpisodes; i++) i];
  for (final e in eps) {
    if (!d.locked.contains(e)) return e;
  }
  return eps.isNotEmpty ? eps.first : 1;
}

class _EpisodeTile extends StatelessWidget {
  final int ep;
  final bool current;
  final bool watched;
  final bool locked;
  final VoidCallback onTap;

  const _EpisodeTile({
    required this.ep,
    required this.current,
    required this.watched,
    this.locked = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (locked) {
      return Material(
        color: AppColors.surface.withValues(alpha: 0.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Stack(
            children: [
              Center(
                child: Text(
                  '$ep',
                  style: const TextStyle(
                    color: AppColors.textFaint,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const Positioned(
                top: 5,
                right: 5,
                child: Icon(Icons.lock_rounded,
                    size: 10, color: AppColors.textFaint),
              ),
            ],
          ),
        ),
      );
    }
    final Color fg = current
        ? AppColors.accent
        : watched
            ? AppColors.textFaint
            : AppColors.text;
    return Material(
      color: current ? const Color(0x1FFF6B5B) : AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: current
            ? const BorderSide(color: AppColors.accent, width: 1.2)
            : BorderSide.none,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Center(
          child: Text(
            '$ep',
            style: TextStyle(
              color: fg,
              fontSize: 15,
              fontWeight: current ? FontWeight.w700 : FontWeight.w500,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }
}

class _BodyPlaceholder extends StatelessWidget {
  const _BodyPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: GridView.count(
        crossAxisCount: 5,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        children: List.generate(
          15,
          (_) => DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.placeholder,
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
      ),
    );
  }
}
