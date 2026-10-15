// Home filter chips ("For you", "Most viewed", genres...) and the pinned
// sliver header that hosts them.
import 'package:flutter/material.dart';

import '../../data/catalog.dart';
import '../../models.dart';
import '../theme.dart';

/// Loads one page (>= 1) of a shelf. Defaults to [catalogShelfFetcher].
typedef ShelfFetcher = Future<Paged<Drama>> Function(String shelfId, int page);

/// Id of the default shelf (the mixed discovery feed).
const String kForYouShelf = 'for_you';

/// Shelf whose cards show a view count.
const String kMostViewedShelf = 'most_viewed';

/// Used when the catalog can't provide its shelf list, so Home still renders.
const List<Shelf> kFallbackShelves = [
  Shelf(kForYouShelf, 'For you'),
  Shelf(kMostViewedShelf, 'Most viewed'),
  Shelf('trending', 'Trending'),
  Shelf('new', 'New'),
  Shelf('g:romance', 'Romance'),
  Shelf('g:billionaire', 'Billionaire'),
  Shelf('g:werewolf', 'Werewolf'),
  Shelf('g:revenge', 'Revenge'),
  Shelf('g:mafia', 'Mafia'),
  Shelf('g:fantasy', 'Fantasy'),
  Shelf('g:vampire', 'Vampire'),
  Shelf('g:rebirth', 'Rebirth'),
  Shelf('g:secret-baby', 'Secret Baby'),
  Shelf('g:marriage', 'Marriage'),
  Shelf('g:dubbed', 'Dubbed'),
];

/// True for genre shelves (`g:<slug>`), false for the sort shelves.
bool isGenreShelf(String id) => id.startsWith('g:');

/// The catalog's shelves, or [kFallbackShelves] if it can't list them.
List<Shelf> catalogShelves() {
  try {
    final list = Catalog.instance.shelves;
    if (list.isNotEmpty) return list;
  } catch (_) {
    // data side not ready — fall through
  }
  return kFallbackShelves;
}

/// Default fetcher: [Catalog.shelf]. 'for_you' falls back to the plain mixed
/// feed while the shelf API isn't implemented.
Future<Paged<Drama>> catalogShelfFetcher(String shelfId, int page) async {
  try {
    return await Catalog.instance.shelf(shelfId, page);
  } on UnimplementedError {
    if (shelfId == kForYouShelf) return Catalog.instance.feed(page);
    rethrow;
  }
}

const double _chipHeight = 32;
const double _barVPad = 8;

/// Total height of the chip bar header.
const double kShelfBarExtent = _chipHeight + _barVPad * 2;

/// Pinned sliver header delegate for [ShelfChipBar].
class ShelfBarDelegate extends SliverPersistentHeaderDelegate {
  final List<Shelf> shelves;
  final String selected;
  final ValueChanged<String> onSelected;

  const ShelfBarDelegate({
    required this.shelves,
    required this.selected,
    required this.onSelected,
  });

  @override
  double get minExtent => kShelfBarExtent;

  @override
  double get maxExtent => kShelfBarExtent;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final pinned = shrinkOffset > 0 || overlapsContent;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border(
          bottom: BorderSide(
            color: pinned ? AppColors.outline : Colors.transparent,
            width: 0.5,
          ),
        ),
      ),
      child: ShelfChipBar(
        shelves: shelves,
        selected: selected,
        onSelected: onSelected,
      ),
    );
  }

  @override
  bool shouldRebuild(ShelfBarDelegate old) =>
      old.selected != selected ||
      old.shelves != shelves ||
      old.onSelected != onSelected;
}

/// Single-row, horizontally scrolling pill chips. A hairline separates the
/// sort shelves from the genre shelves.
class ShelfChipBar extends StatefulWidget {
  final List<Shelf> shelves;
  final String selected;
  final ValueChanged<String> onSelected;

  const ShelfChipBar({
    super.key,
    required this.shelves,
    required this.selected,
    required this.onSelected,
  });

  @override
  State<ShelfChipBar> createState() => _ShelfChipBarState();
}

class _ShelfChipBarState extends State<ShelfChipBar> {
  final _keys = <String, GlobalKey>{};
  final _hScroll = ScrollController();

  @override
  void dispose() {
    _hScroll.dispose();
    super.dispose();
  }

  GlobalKey _keyFor(String id) => _keys.putIfAbsent(id, GlobalKey.new);

  @override
  void didUpdateWidget(ShelfChipBar old) {
    super.didUpdateWidget(old);
    if (old.selected != widget.selected) {
      // Bring the newly selected chip into view — horizontally only
      // (Scrollable.ensureVisible would also scroll the Home grid).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ro = _keys[widget.selected]?.currentContext?.findRenderObject();
        if (ro == null || !ro.attached || !_hScroll.hasClients) return;
        _hScroll.position.ensureVisible(
          ro,
          alignment: 0.5,
          alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    final shelves = widget.shelves;
    for (var i = 0; i < shelves.length; i++) {
      final s = shelves[i];
      if (i > 0) {
        children.add(const SizedBox(width: 8));
        if (isGenreShelf(s.id) && !isGenreShelf(shelves[i - 1].id)) {
          children
            ..add(const _Hairline())
            ..add(const SizedBox(width: 8));
        }
      }
      children.add(ShelfChip(
        key: _keyFor(s.id),
        label: s.label,
        selected: s.id == widget.selected,
        onTap: () => widget.onSelected(s.id),
      ));
    }
    return SingleChildScrollView(
      controller: _hScroll,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: _barVPad),
      child: Row(children: children),
    );
  }
}

class _Hairline extends StatelessWidget {
  const _Hairline();

  @override
  Widget build(BuildContext context) =>
      const SizedBox(width: 1, height: 16, child: ColoredBox(color: AppColors.outline));
}

/// Minimal pill: selected = filled off-white with dark text; unselected =
/// hairline outline with muted text.
class ShelfChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const ShelfChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const shape = StadiumBorder();
    return Semantics(
      button: true,
      selected: selected,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        height: _chipHeight,
        decoration: ShapeDecoration(
          color: selected ? AppColors.text : Colors.transparent,
          shape: StadiumBorder(
            side: BorderSide(
              color: selected ? AppColors.text : AppColors.outline,
            ),
          ),
        ),
        child: Material(
          type: MaterialType.transparency,
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: shape,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Center(
                widthFactor: 1,
                child: Text(
                  label,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1,
                    letterSpacing: 0.1,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected ? AppColors.background : AppColors.textMuted,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
