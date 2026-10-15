// OWNER: player agent.
//
// Minimal dark bottom sheets: episode grid, quality, playback speed.
import 'package:flutter/material.dart';

const _sheetColor = Color(0xFF111111);
const kPlaybackSpeeds = [0.75, 1.0, 1.25, 1.5, 2.0];

String formatSpeed(double s) {
  final t = s == s.roundToDouble() ? s.toStringAsFixed(0) : s.toString();
  return '${t}x';
}

Future<T?> _show<T>(BuildContext context, String title, Widget child) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: _sheetColor,
    barrierColor: Colors.black38,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: BoxConstraints(
      maxWidth: 560,
      maxHeight: MediaQuery.sizeOf(context).height * 0.7,
    ),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (context) => SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 8, bottom: 12),
              width: 32,
              height: 3,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Flexible(child: child),
          const SizedBox(height: 12),
        ],
      ),
    ),
  );
}

/// Returns the chosen episode number. Episodes in [locked] are greyed out
/// with a small lock and can't be picked.
Future<int?> showEpisodeSheet(
  BuildContext context, {
  required List<int> episodes,
  required Set<int> locked,
  required int current,
}) {
  return _show<int>(
    context,
    'Episodes · ${episodes.length}',
    GridView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 64,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 1.25,
      ),
      itemCount: episodes.length,
      itemBuilder: (context, i) {
        final ep = episodes[i];
        final isCurrent = ep == current;
        final isLocked = locked.contains(ep);
        return Material(
          color: isCurrent
              ? Colors.white
              : isLocked
                  ? const Color(0xFF161616)
                  : const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: isLocked ? null : () => Navigator.of(context).pop(ep),
            child: Stack(
              children: [
                Center(
                  child: Text(
                    '$ep',
                    style: TextStyle(
                      color: isCurrent
                          ? Colors.black
                          : isLocked
                              ? Colors.white24
                              : Colors.white,
                      fontSize: 14,
                      fontWeight:
                          isCurrent ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
                if (isLocked)
                  const Positioned(
                    top: 4,
                    right: 4,
                    child: Icon(Icons.lock_rounded,
                        size: 9, color: Colors.white24),
                  ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

Future<String?> showQualitySheet(
  BuildContext context, {
  required List<String> options,
  required String? current,
}) {
  return _show<String>(
    context,
    'Quality',
    ListView(
      shrinkWrap: true,
      children: [
        for (final o in options)
          _OptionTile(
            label: o,
            selected: o == current,
            onTap: () => Navigator.of(context).pop(o),
          ),
      ],
    ),
  );
}

Future<double?> showSpeedSheet(BuildContext context, {required double current}) {
  return _show<double>(
    context,
    'Playback speed',
    ListView(
      shrinkWrap: true,
      children: [
        for (final s in kPlaybackSpeeds)
          _OptionTile(
            label: s == 1.0 ? 'Normal' : formatSpeed(s),
            selected: s == current,
            onTap: () => Navigator.of(context).pop(s),
          ),
      ],
    ),
  );
}

class _OptionTile extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _OptionTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: selected ? Colors.white : Colors.white70,
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            if (selected)
              const Icon(Icons.check_rounded, color: Colors.white, size: 18),
          ],
        ),
      ),
    );
  }
}
