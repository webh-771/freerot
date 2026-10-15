import 'package:flutter/material.dart';

import '../../data/library.dart';
import '../../models.dart';
import '../nav.dart';
import '../theme.dart';
import '../widgets/poster.dart';
import '../widgets/states.dart';

/// Saved dramas + watch history.
class MyListScreen extends StatelessWidget {
  const MyListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 16,
          title: const Text('My List'),
          bottom: const PreferredSize(
            preferredSize: Size.fromHeight(44),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TabBar(
                isScrollable: true,
                padding: EdgeInsets.symmetric(horizontal: 4),
                labelPadding: EdgeInsets.symmetric(horizontal: 12),
                tabs: [Tab(text: 'Saved'), Tab(text: 'History')],
              ),
            ),
          ),
        ),
        body: ListenableBuilder(
          listenable: Library.instance,
          builder: (context, _) => TabBarView(
            children: [
              _SavedGrid(items: Library.instance.myList),
              _HistoryList(items: Library.instance.continueWatching),
            ],
          ),
        ),
      ),
    );
  }
}

class _SavedGrid extends StatelessWidget {
  final List<Drama> items;
  const _SavedGrid({required this.items});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const EmptyView(
        icon: Icons.bookmark_border_rounded,
        message: 'Dramas you add to My List show up here.',
      );
    }
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          sliver: SliverGrid(
            gridDelegate:
                PosterGridDelegate(footerExtent: posterFooterExtent(context)),
            delegate: SliverChildBuilderDelegate(
              (context, i) {
                final d = items[i];
                return Poster(
                  key: ValueKey(d.key),
                  drama: d,
                  onTap: () => openDetail(context, d),
                  onLongPress: () => _confirmUnsave(context, d),
                );
              },
              childCount: items.length,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmUnsave(BuildContext context, Drama d) async {
    final remove = await showModalBottomSheet<bool>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(d.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Remove from My List'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
    if (remove == true && Library.instance.inMyList(d.key)) {
      await Library.instance.toggleMyList(d);
    }
  }
}

class _HistoryList extends StatelessWidget {
  final List<WatchProgress> items;
  const _HistoryList({required this.items});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const EmptyView(
        icon: Icons.history_rounded,
        message: "What you watch will show up here.",
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 24),
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 16),
      itemBuilder: (context, i) => _HistoryRow(
        key: ValueKey(items[i].drama.key),
        p: items[i],
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  final WatchProgress p;
  const _HistoryRow({super.key, required this.p});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = p.drama.episodes;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => resumeProgress(context, p),
      onLongPress: () => openDetail(context, p.drama),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: PosterImage(
              url: p.drama.cover,
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.drama.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    total != null ? 'EP ${p.ep} of $total' : 'EP ${p.ep}',
                    _ago(p.updatedAt),
                  ].join('  ·  '),
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: p.fraction,
                    minHeight: 2,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Remove',
            icon: const Icon(Icons.close_rounded,
                color: AppColors.textFaint, size: 20),
            onPressed: () => Library.instance.removeProgress(p.drama.key),
          ),
        ],
      ),
    );
  }

  static String _ago(int epochMs) {
    final d = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(epochMs));
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes}m ago';
    if (d.inDays < 1) return '${d.inHours}h ago';
    if (d.inDays < 7) return '${d.inDays}d ago';
    return '${(d.inDays / 7).floor()}w ago';
  }
}
